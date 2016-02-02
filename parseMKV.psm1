<#
.SYNOPSIS
    Parses an MKV file

.DESCRIPTION
    Parses an MKV file and optionally prints the structure to console

.OUTPUTS
    System.Collections.Specialized.OrderedDictionary

.PARAMETER filepath
    Input file path

.PARAMETER stopOn
    Stop parsing when a tag ID matches the regex pattern, case-insensitive, specify an empty string to disable

.PARAMETER binarySizeLimit
    Do not autoread binary data bigger than this number of bytes, specify -1 for no limit

.PARAMETER entryCallback
    Code block to be called on each entry. Some time/date/tracktype values are yet raw numbers because processing happens after all child elements of a container are read.
    Parameters: entry (with its metadata in _ property).
    Code block may return 'abort' to stop all processing, otherwise the output is ignored.
    //TODO: consider allowing to 'skip' current element.

.PARAMETER keepStreamOpen
    Leave the BinaryReader stream open in <result>._.reader

.PARAMETER print
    Pretty-print to the console.

.PARAMETER printMatch
    Only elements with names matching the provided regexp will be printed.
    By default 'SeekHead', 'EBML', 'Void' elements are skipped.
    Empty = print everything.

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -print

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv'`

    $mkv.Tracks.Video | %{ 'Video: {0}x{1}, {2}' -f $_.Video.PixelWidth, $_.Video.PixelHeight, $_.CodecID }
    $isMultiAudio = $mkv.Tracks.Audio.Capacity -gt 1
    $mkv.Tracks.Audio | %{ $index=0 } { 'Audio{0}: {1}{2}' -f (++$index), $_.CodecID, $_.Audio.SamplingFrequency }

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv' -stopOn 'tracks' -binarySizeLimit 0

    $duration = $mkv.Info.Duration

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv' -keepStreamOpen -binarySizeLimit 0

    $mkv.Attachments.AttachedFile | %{
        $file = [IO.File]::create($_.FileName)
        $size = $_.FileData._.size
        $mkv._.reader.baseStream.position = $_.FileData._.datapos
        $data = $mkv._.reader.readBytes($size)
        $file.write($data, 0, $size)
        $file.close()
    }
    $mkv._.reader.close()
#>

function parseMKV(
    [string]$filepath,
    [string]$stopOn = 'cluster',
    [int]$binarySizeLimit = 16,
    [scriptblock]$entryCallback,
    [switch]$keepStreamOpen,
    [switch]$print,
    [string]$printMatch = '^(?!(SeekHead|EBML|Void)$)'
) {
    try {
        $file = [IO.File]::open($filepath, [IO.FileMode]::open, [IO.FileAccess]::read, [IO.FileShare]::read)
        $stream = new-object IO.BufferedStream $file, 32 # otherwise it stupidly reads ahead 4kB every seek(!)
        $bin = [IO.BinaryReader] $stream
    } catch {
        throw $_
        return $null
    }
    $script:abort = $false # used for 'stopOn' parameter

    initDTD
    $header = readRootContainer EBML
    $segment = if (!$script:abort) { readRootContainer Segment }

    if ([bool]$keepStreamOpen) {
        $segment._.reader = $bin
    } else {
        $bin.close()
        $stream.close()
    }

    if ([bool]$print) { write-host '' }

    $segment
}

function readRootContainer([string]$requiredID) {
    if ($stream.position -ge $stream.length) {
        return $null
    }

    $container = readEntry
    $container._.level = 0
    $container._.root = $container

    if ($container -eq $null -or $container._.type -ne 'container') {
        write-verbose 'Not a container'
        return $null
    }
    if ($requiredID -and $container._.name -ne $requiredID) {
        write-verbose "Expected $requiredID but got $($container._.name)"
        return $null
    }
    if ($entryCallback -and (& $entryCallback $child) -eq 'abort') {
        $script:abort = $true;
        return
    }
    if ([bool]$print) {
        printEntry $container
    }

    readChildren $container
    $container
}

function readChildren([Collections.Specialized.OrderedDictionary]$container) {
    $stream.position = $container._.datapos
    $stopAt = $container._.datapos + $container._.size

    while ($stream.position -lt $stopAt) {
        $child = readEntry
        if ($child -eq $null) {
            break
        }
        $child._.level = $container._.level + 1
        $child._.root = $container._.root
        $child._.parent = $container

        addNamedChild $container $child._.name $child
        if ($entryCallback -and (& $entryCallback $child) -eq 'abort') {
            $script:abort = $true;
            break
        }

        if ($child._.type -eq 'container') {
            if ([bool]$print) {
                printEntry $child
            }
            readChildren $child
            if ($script:abort) {
                break
            }
        }
    }
    cookChildren $container

    if ([bool]$print -and !$script:abort) {
        printChildren $container
    }
}

function readEntry {
    # inline the code because PowerShell's overhead for a simple function call
    # is bigger than the time to execute it

    $pos = $stream.position

    $head = [uint64]$bin.ReadByte()
    $id = if ($head -eq 0 -or $head -eq 0xFF) {
        write-warning "BAD ID $head"
        -1
    } else {
        $len = 1; [uint64]$tail = 0;
        # max value in 4 bytes is (2^28 - 2)
        for ($mask = 0x80; $head -lt $mask; $mask = $mask -shr 1) {
            $tail = [uint64]$tail -shl 8 -bor $bin.readByte()
            $len++
        }
        if ($len -le 4) { $head = [int]$head; $tail = [int]$tail }
        $head -shl (($len-1)*8) -bor $tail
    }

    $info = $DTD.IDs['{0:x}' -f $id]

    $size = if ($info -and $info.size -ne $null) {
        $info.size
    } else {
        $head = [uint64]$bin.ReadByte()
        if ($head -eq 0 -or $head -eq 0xFF) {
            write-warning "BAD SIZE $head"
            -1
        } else {
            $len = 1; [uint64]$tail = 0;
            # max value in 4 bytes is (2^28 - 2)
            for ($mask = 0x80; $head -lt $mask; $mask = $mask -shr 1) {
                $tail = [uint64]$tail -shl 8 -bor $bin.readByte()
                $len++
            }
            if ($len -le 4) { $head = [int]$head; $tail = [int]$tail }
            ($head -band -bnot [byte]$mask) -shl (($len-1)*8) -bor $tail
        }
    }

    $meta = @{
        id=$id;
        pos=$pos;
        size=$size;
        datapos=$stream.position
    }

    if (!$info) {
        write-warning ("{0,8}: {1,8:x}`tUnknown EBML ID" -f $pos, $id)
        return (@{} | add-member _ $meta -passthru)
    }
    if ($stopOn -and $info.name -match $stopOn) {
        $stream.position += $size
        return $null
    }

    $meta += @{
        name=$info.name;
        type=$info.type
    }

    if ($size) {
        switch ($info.type) {
            'int' {
                $bytes = $bin.readBytes($size)
                if ($size -eq 8) {
                    [Array]::reverse($bytes)
                    $value = [BitConverter]::toInt64($bytes, 0)
                } else {
                    [uint64]$v = 0
                    foreach ($b in $bytes) { $v = $v -shl 8 -bor $b }
                    $value = [int64]$v - ([uint64]1 -shl $size*8)
                }
            }
            'uint' {
                $bytes = $bin.readBytes($size)
                [uint64]$value = 0
                foreach ($b in $bytes) { $value = $value -shl 8 -bor $b }
            }
            'float' {
                $bytes = $bin.readBytes($size)
                [Array]::reverse($bytes)
                switch ($size) {
                    4 { $value = [BitConverter]::toSingle($bytes, 0) }
                    8 { $value = [BitConverter]::toDouble($bytes, 0) }
                    10 { $value = [Nato.LongDouble.BitConverter]::toDouble($bytes, 0) }
                }
            }
            'date' {
                if ($size -ne 8) {
                    write-warning "DATE should be 8 bytes, got $size"
                    $rawvalue = 0
                } else {
                    $bytes = $bin.readBytes(8)
                    [Array]::reverse($bytes)
                    $rawvalue = [BitConverter]::toInt64($bytes,0)
                }
                $value = ([datetime]'2001-01-01T00:00:00.000Z').addTicks($rawvalue/100)
            }
            'string' {
                $value = [Text.Encoding]::UTF8.getString($bin.readBytes($size))
            }
            'binary' {
                $readSize = if ($binarySizeLimit -lt 0) { $size }
                            else { [Math]::min($binarySizeLimit,$size) }
                if ($readSize) {
                    $value = $bin.ReadBytes($readSize)
                } else {
                    $value = [byte[]]@()
                }
            }
            'container' {
                $value = [ordered]@{}
            }
            default {
                $value = @{}
            }
        }
        $stream.position = $meta.datapos + $size
    } elseif ($info.value -ne $null) {
        $value = $info.value
    } else {
        switch ($meta.type) {
            'int'       { $value = 0 }
            'uint'      { $value = 0 }
            'float'     { $value = 0.0 }
            'string'    { $value = '' }
            'container' { $value = [ordered]@{} }
            default     { $value = @{} }
        }
    }

    $typecast = switch ($info.type) {
        'int'  { if ($size -le 4) { [int32] } else { [int64] } }
        'uint' { if ($size -le 4) { [uint32] } else { [uint64] } }
        'float' { if ($size -eq 4) { [single] } else { [double] } }
    }
    # using explicit assignment to keep empty values which are lost in $var=if(...) {val1} else {val2}
    if ($typecast) { $result = $value -as $typecast } else { $result = $value }
    add-member _ $meta -inputObject $result -passthru
}

function cookChildren([Collections.Specialized.OrderedDictionary]$container) {
    function setValue($entry, $newValue) {
        $meta = $entry._
        $raw = $entry.PSObject.copy(); $raw.PSObject.members.remove('_')
        $entry = add-member _ ($meta + @{rawValue=$raw}) -inputObject $newValue -passthru
        $entry._.parent[$meta.name] = $entry
        $entry
    }
    function bakeTime($entry, [switch]$noScaling) {
        if ($entry -eq $null) {
            return
        }
        $nanoseconds = [uint64]$entry
        if (![bool]$noScaling) {
            $nanoseconds *= $entry._.root.Info.TimecodeScale # scale is a mandatory element
        }
        $time = new-object TimeSpan ([uint64]$nanoseconds / 100)
        $entry = setValue $entry $time
        $seconds = [Math]::round($nanoseconds/1000000000, 3)
        $entry._.displayString = '{0}s ({1:hh\:mm\:ss\.fff})' -f `
            $seconds.toString([Globalization.CultureInfo]::InvariantCulture),
            $time
        $entry
    }
    function bakeUID($UID) {
        if ($UID) {
            $UID._.displayString = bin2hex $UID
        }
    }
    switch ($container._.name) {
        'Info' {
            bakeTime $container.Duration >$null
            bakeUID $container.SegmentUID
        }
        'ChapterAtom' {
            'Start', 'End' | %{
                $time = $container["ChapterTime$_"]
                if ($time -ne $null) {
                    $time = setValue $time (new-object TimeSpan ([uint64]$time / 100))
                    $time._.displayString = '{0:hh\:mm\:ss\.fff}' -f $time
                }
            }
            bakeUID $container.ChapterSegmentUID
        }
        'TrackEntry' {
            $trackType = switch ($container.TrackType) { # mandatory element
                1 { 'Video' }
                2 { 'Audio' }
                0x10 { 'Logo' }
                0x11 { 'Subtitle' }
                0x12 { 'Buttons' }
                0x20 { 'Control' }
            }
            addNamedChild $container._.parent (setValue $container.TrackType $trackType) $container
            if ($container.DefaultDuration) {
                $duration = bakeTime $container.DefaultDuration -noScaling
                if ($trackType -eq 'Video') {
                    $extraFormat = ', {1} fps'
                    $fps = [math]::round(1000000000 / $duration._.rawValue, 3)
                    $fps = $fps.toString([Globalization.CultureInfo]::InvariantCulture)
                }
                $duration._.displayString = "{0:0}ms$extraFormat" -f $duration.totalMilliseconds, $fps
            }
        }
        'Cluster' {
            bakeTime $container.Timecode >$null # mandatory element
        }
    }
}

function printChildren([Collections.Specialized.OrderedDictionary]$container) {
    foreach ($child in $container.values) {
        if ($child._.type -ne 'container') {
            if ($child -is [Collections.ArrayList]) {
                $child | %{ printEntry $_ }
            } else {
                printEntry $child
            }
        }
    }
}

function printEntry($entry) {
    $meta = $entry._
    $last = $script:lastPrinted

    if ($printMatch) {
        for ($e = $entry; $e -ne $null; $e = $e._.parent) {
            if (!($e._.name -match $printMatch)) {
                return
            }
        }
    }

    $emptyBinary = $entry._.type -eq 'binary' -and !$entry.length
    if ($emptyBinary -and $last -and $last.emptyBinary -and $last.id -eq $meta.id) {
        $last.skipped++
        write-host -n .
        return
    }
    if ($last) {
        if ($last.skipped) { write-host -f darkgray " [$($last.skipped)]" }
        else { write-host '' }
    }
    $script:lastPrinted = @{ id=$meta.id; emptyBinary=$emptyBinary }

    $color = if ($meta.type -eq 'container') { 'white' } else { 'gray' }
    write-host -n -f $color (('  '*$meta.level) + $meta.name + ' ')

    $s = if ($meta.displayString) {
        $meta.displayString
    } elseif ($entry._.type -eq 'binary') {
        if ($entry.length) {
            $ellipsis = if ($entry.length -lt $meta.size) { '...' } else { '' }
            "[$($meta.size) bytes] $((bin2hex $entry) -replace '(.{8})', '$1 ')$ellipsis"
        }
    } elseif ($entry._.type -ne 'container') {
        "$entry"
    }
    $color = if ($meta.name -match 'UID$') { 'darkgray' }
             else { switch ($meta.type) { string { 'green' } binary { 'darkgray' } default { 'yellow' } } }
    write-host -n -f $color $s
}

function addNamedChild([Collections.Specialized.OrderedDictionary]$dict, [string]$key, $value) {
    $current = $dict[$key]
    if ($current -eq $null) {
        $dict[$key] = $value
    } elseif ($current -is [Collections.ArrayList]) {
        $current.add($value) >$null
    } else {
        $dict[$key] = [Collections.ArrayList] @($current, $value)
    }
}

function flattenDTD([hashtable]$dict, [bool]$byID, [hashtable]$flat=@{}) {
    foreach ($i in $dict.getEnumerator()) {
        $v = $i.value
        if ($byID) {
            $flat['{0:x}' -f $v.id] = $v
            $v.name = $i.key
        } else {
            $flat[$i.key] = $v
        }
        if ($v.children) {
            $flat = flattenDTD $v.children $byID $flat
        }
    }
    $flat
}

function bin2hex([byte[]]$value) {
    if ($value) { [BitConverter]::toString($value) -replace '-', '' }
    else { '' }
}

add-type @'
/* Author:
 *  - Nathan Baulch (nbaulch@bigpond.net.au
 *
 * References:
 *  - http://cch.loria.fr/documentation/IEEE754/numerical_comp_guide/ncg_math.doc.html
 *  - http://groups.google.com/groups?selm=MPG.19a6985d4683f5d398a313%40news.microsoft.com
 */

using System;

namespace Nato.LongDouble
{
    public class BitConverter
    {
        //converts the next 10 bytes of Value starting at StartIndex into a double
        public static double ToDouble(byte[] Value,int StartIndex)
        {
            if(Value == null)
                throw new ArgumentNullException("Value");

            if(Value.Length < StartIndex + 10)
                throw new ArgumentException("Combination of Value length and StartIndex was not large enough.");

            //extract fields
            byte s = (byte)(Value[9] & 0x80);
            short e = (short)(((Value[9] & 0x7F) << 8) | Value[8]);
            byte j = (byte)(Value[7] & 0x80);
            long f = Value[7] & 0x7F;
            for(sbyte i = 6; i >= 0; i--)
            {
                f <<= 8;
                f |= Value[i];
            }

            if(e == 0) //subnormal, pseudo-denormal or zero
                return 0;

            if(j == 0)
                throw new NotSupportedException();

            if(e == 0x7FFF) //+infinity, -infinity or nan
            {
                if(f != 0)
                    return double.NaN;
                if(s == 0)
                    return double.PositiveInfinity;
                else
                    return double.NegativeInfinity;
            }

            //translate f
            f >>= 11;

            //translate e
            e -= (0x3FFF - 0x3FF);

            if(e >= 0x7FF) //outside the range of a double
                throw new OverflowException();
            else if(e < -51) //too small to translate into subnormal
                return 0;
            else if(e < 0) //too small for normal but big enough to represent as subnormal
            {
                f |= 0x10000000000000;
                f >>= (1 - e);
                e = 0;
            }

            byte[] newBytes = System.BitConverter.GetBytes(f);

            newBytes[7] = (byte)(s | (e >> 4));
            newBytes[6] = (byte)(((e & 0x0F) << 4) | newBytes[6]);

            return System.BitConverter.ToDouble(newBytes,0);
        }

    }
}
'@

function initDTD {
    if ($script:DTD) {
        return
    }
    $script:DTD = @{
        EBML = @{ id=0x1a45dfa3; type='container'; children = @{
            EBMLVersion = @{ id=0x4286; type='uint'; value=1 };
            EBMLReadVersion = @{ id=0x42f7; type='uint'; value=1 };
            EBMLMaxIDLength = @{ id=0x42f2; type='uint'; value=4 };
            EBMLMaxSizeLength = @{ id=0x42f3; type='uint'; value=8 };
            DocType = @{ id=0x4282; type='string' };
            DocTypeVersion = @{ id=0x4287; type='uint'; value=1 };
            DocTypeReadVersion = @{ id=0x4285; type='uint'; value=1 };
        }};
        CRC32 = @{ id=0xbf; type='binary' };
        Void = @{ id=0xec; type='binary' };
        Dummy = @{ id=0xff; type='binary' };

        # Matroska DTD
        Segment = @{ id=0x18538067; type='container'; children = @{

            # Meta Seek Information
            SeekHead = @{ id=0x114d9b74; type='container'; children = @{
                Seek = @{ id=0x4dbb; type='container'; children = @{
                    SeekID = @{ id=0x53ab; type='binary' };
                    SeekPosition = @{ id=0x53ac; type='uint' };
                }}
            }};

            # Segment Information
            Info = @{ id=0x1549a966; type='container'; children = @{
                SegmentUID = @{ id=0x73a4; type='binary' };
                SegmentFilename = @{ id=0x7384; type='string' };
                PrevUID = @{ id=0x3cb923; type='binary' };
                PrevFilename = @{ id=0x3c83ab; type='string' };
                NextUID = @{ id=0x3eb923; type='binary' };
                NextFilename = @{ id=0x3e83bb; type='string' };
                SegmentFamily = @{ id=0x4444; type='binary' };
                ChapterTranslate = @{ id=0x6924; type='container'; children = @{
                    ChapterTranslateEditionUID = @{ id=0x69fc; type='uint' };
                    ChapterTranslateCodec = @{ id=0x69bf; type='uint' };
                    ChapterTranslateID = @{ id=0x69a5; type='binary' };
                }};
                TimecodeScale = @{ id=0x2ad7b1; type='uint'; value=1000000 };
                Duration = @{ id=0x4489; type='float' };
                DateUTC = @{ id=0x4461; type='date' };
                Title = @{ id=0x7ba9; type='string' };
                MuxingApp = @{ id=0x4d80; type='string' };
                WritingApp = @{ id=0x5741; type='string' };
            }};

            # Cluster
            Cluster = @{ id=0x1f43b675; type='container'; children = @{
                Timecode = @{ id=0xe7; type='uint' };
                SilentTracks = @{ id=0x5854; type='container'; children = @{
                    SilentTrackNumber = @{ id=0x58d7; type='uint' };
                }};
                Position = @{ id=0xa7; type='uint' };
                PrevSize = @{ id=0xab; type='uint' };
                SimpleBlock = @{ id=0xa3; type='binary' };
                BlockGroup = @{ id=0xa0; type='container'; children = @{
                    Block = @{ id=0xa1; type='binary' };
                    BlockVirtual = @{ id=0xa2; type='binary' };
                    BlockAdditions = @{ id=0x75a1; type='container'; children = @{
                        BlockMore = @{ id=0xa6; type='container'; children = @{
                            BlockAddID = @{ id=0xee; type='uint' };
                            BlockAdditional = @{ id=0xa5; type='binary' };
                        }}
                    }}
                    BlockDuration = @{ id=0x9b; type='uint' };
                    ReferencePriority = @{ id=0xfa; type='uint' };
                    ReferenceBlock = @{ id=0xfb; type='int' };
                    ReferenceVirtual = @{ id=0xfd; type='int' };
                    CodecState = @{ id=0xa4; type='binary' };
                    DiscardPadding = @{ id=0x75a2; type='int' };
                    Slices = @{ id=0x8e; type='container'; children = @{
                        TimeSlice = @{ id=0xe8; type='container'; children = @{
                            LaceNumber = @{ id=0xcc; type='uint'; value=0 };
                            FrameNumber = @{ id=0xcd; type='uint'; value=0 };
                            BlockAdditionID = @{ id=0xcb; type='uint'; value=0 };
                            Delay = @{ id=0xce; type='uint'; value=0 };
                            SliceDuration = @{ id=0xcf; type='uint' };
                        }}
                    }};
                    ReferenceFrame = @{ id=0xc8; type='container'; children = @{
                        ReferenceOffset = @{ id=0xc9; type='uint'; value=0 };
                        ReferenceTimeCode = @{ id=0xca; type='uint'; value=0 };
                    }};
                EncryptedBlock = @{ id=0xaf; type='binary' };
                }}
            }};

            # Track
            Tracks = @{ id=0x1654ae6b; type='container'; children = @{
                TrackEntry = @{ id=0xae; type='container'; children = @{
                    TrackNumber = @{ id=0xd7; type='uint' };
                    TrackUID = @{ id=0x73c5; type='uint' };
                    TrackType = @{ id=0x83; type='uint' };
                    FlagEnabled = @{ id=0xb9; type='uint'; value=1 };
                    FlagDefault = @{ id=0x88; type='uint'; value=1 };
                    FlagForced = @{ id=0x55aa; type='uint'; value=0 };
                    FlagLacing = @{ id=0x9c; type='uint'; value=1 };
                    MinCache = @{ id=0x6de7; type='uint'; value=0 };
                    MaxCache = @{ id=0x6df8; type='uint' };
                    DefaultDuration = @{ id=0x23e383; type='uint' };
                    DefaultDecodedFieldDuration = @{ id=0x234e7a; type='uint' };
                    TrackTimecodeScale = @{ id=0x23314f; type='float'; value=1.0 };
                    TrackOffset = @{ id=0x537f; type='int'; value=0 };
                    MaxBlockAdditionID = @{ id=0x55ee; type='uint'; value=0 };
                    Name = @{ id=0x536e; type='string' };
                    Language = @{ id=0x22b59c; type='string'; value="eng" };
                    CodecID = @{ id=0x86; type='string' };
                    CodecPrivate = @{ id=0x63a2; type='binary' };
                    CodecName = @{ id=0x258688; type='string' };
                    AttachmentLink = @{ id=0x7446; type='uint' };
                    CodecSettings = @{ id=0x3a9697; type='string' };
                    CodecInfoURL = @{ id=0x3b4040; type='string' };
                    CodecDownloadURL = @{ id=0x26b240; type='string' };
                    CodecDecodeAll = @{ id=0xaa; type='uint'; value=1 };
                    TrackOverlay = @{ id=0x6fab; type='uint' };
                    CodecDelay = @{ id=0x56aa; type='uint' };
                    SeekPreRoll = @{ id=0x56bb; type='uint' };
                    TrackTranslate = @{ id=0x6624; type='container'; children = @{
                        TrackTranslateEditionUID = @{ id=0x66fc; type='uint' };
                        TrackTranslateCodec = @{ id=0x66bf; type='uint' };
                        TrackTranslateTrackID = @{ id=0x66a5; type='binary' };
                    }};

                    # Video
                    Video = @{ id=0xe0; type='container'; children = @{
                        FlagInterlaced = @{ id=0x9a; type='uint'; value=0 };
                        StereoMode = @{ id=0x53b8; type='uint'; value=0 };
                        AlphaMode = @{ id=0x53c0; type='uint' };
                        OldStereoMode = @{ id=0x53b9; type='uint' };
                        PixelWidth = @{ id=0xb0; type='uint' };
                        PixelHeight = @{ id=0xba; type='uint' };
                        PixelCropBottom = @{ id=0x54aa; type='uint' };
                        PixelCropTop = @{ id=0x54bb; type='uint' };
                        PixelCropLeft = @{ id=0x54cc; type='uint' };
                        PixelCropRight = @{ id=0x54dd; type='uint' };
                        DisplayWidth = @{ id=0x54b0; type='uint' };
                        DisplayHeight = @{ id=0x54ba; type='uint' };
                        DisplayUnit = @{ id=0x54b2; type='uint'; value=0 };
                        AspectRatioType = @{ id=0x54b3; type='uint'; value=0 };
                        ColourSpace = @{ id=0x2eb524; type='binary' };
                        GammaValue = @{ id=0x2fb523; type='float' };
                        FrameRate = @{ id=0x2383e3; type='float' };
                    }}

                    # Audio
                    Audio = @{ id=0xe1; type='container'; children = @{
                        SamplingFrequency = @{ id=0xb5; type='float'; value=8000.0 };
                        OutputSamplingFrequency = @{ id=0x78b5; type='float'; value=8000.0 };
                        Channels = @{ id=0x9f; type='uint'; value=1 };
                        ChannelPositions = @{ id=0x7d7b; type='binary' };
                        BitDepth = @{ id=0x6264; type='uint' };
                    }};

                    TrackOperation = @{ id=0xe2; type='container'; children = @{
                        TrackCombinePlanes = @{ id=0xe3; type='container'; children = @{
                            TrackPlane = @{ id=0xe4; type='container'; children = @{
                                TrackPlaneUID = @{ id=0xe5; type='uint' };
                                TrackPlaneType = @{ id=0xe6; type='uint' };
                            }};
                        }};
                        TrackJoinBlocks = @{ id=0xe9; type='container'; children = @{
                            TrackJoinUID = @{ id=0xed; type='uint' };
                        }}
                    }};

                    TrickTrackUID = @{ id=0xc0; type='uint' };
                    TrickTrackSegmentUID = @{ id=0xc1; type='binary' };
                    TrickTrackFlag = @{ id=0xc6; type='uint' };
                    TrickMasterTrackUID = @{ id=0xc7; type='uint' };
                    TrickMasterTrackSegmentUID = @{ id=0xc4; type='binary' };

                    # Content Encoding
                    ContentEncodings = @{ id=0x6d80; type='container'; children = @{
                        ContentEncoding = @{ id=0x6240; type='container'; children = @{
                            ContentEncodingOrder = @{ id=0x5031; type='uint'; value=0 };
                            ContentEncodingScope = @{ id=0x5032; type='uint'; value=1 };
                            ContentEncodingType = @{ id=0x5033; type='uint' };
                            ContentCompression = @{ id=0x5034; type='container'; children = @{
                                ContentCompAlgo = @{ id=0x4254; type='uint'; value=0 };
                                ContentCompSettings = @{ id=0x4255; type='binary' };
                            }}
                            ContentEncryption = @{ id=0x5035; type='container'; children = @{
                                ContentEncAlgo = @{ id=0x47e1; type='uint'; value=0 };
                                ContentEncKeyID = @{ id=0x47e2; type='binary' };
                                ContentSignature = @{ id=0x47e3; type='binary' };
                                ContentSigKeyID = @{ id=0x47e4; type='binary' };
                                ContentSigAlgo = @{ id=0x47e5; type='uint' };
                                ContentSigHashAlgo = @{ id=0x47e6; type='uint' };
                            }}
                        }}
                    }}
                }}
            }};

            # Cueing Data
            Cues = @{ id=0x1c53bb6b; type='container'; children = @{
                CuePoint = @{ id=0xbb; type='container'; children = @{
                    CueTime = @{ id=0xb3; type='uint' };
                    CueTrackPositions = @{ id=0xb7; type='container'; children = @{
                        CueTrack = @{ id=0xf7; type='uint' };
                        CueClusterPosition = @{ id=0xf1; type='uint' };
                        CueRelativePosition = @{ id=0xf0; type='uint' };
                        CueDuration = @{ id=0xb2; type='uint' };
                        CueBlockNumber = @{ id=0x5378; type='uint'; value=1 };
                        CueCodecState = @{ id=0xea; type='uint'; value=0 };
                        CueReference = @{ id=0xdb; type='container'; children = @{
                            CueRefTime = @{ id=0x96; type='uint' };
                            CueRefCluster = @{ id=0x97; type='uint' };
                            CueRefNumber = @{ id=0x535f; type='uint'; value=1 };
                            CueRefCodecState = @{ id=0xeb; type='uint'; value=0 };
                        }}
                    }}
                }}
            }};

            # Attachment
            Attachments = @{ id=0x1941a469; type='container'; children = @{
                AttachedFile = @{ id=0x61a7; type='container'; children = @{
                    FileDescription = @{ id=0x467e; type='string' };
                    FileName = @{ id=0x466e; type='string' };
                    FileMimeType = @{ id=0x4660; type='string' };
                    FileData = @{ id=0x465c; type='binary' };
                    FileUID = @{ id=0x46ae; type='uint' };
                    FileReferral = @{ id=0x4675; type='binary' };
                    FileUsedStartTime = @{ id=0x4661; type='uint' };
                    FileUsedEndTime = @{ id=0x4662; type='uint' };
                }}
            }};

            # Chapters
            Chapters = @{ id=0x1043a770; type='container'; children = @{
                EditionEntry = @{ id=0x45b9; type='container'; children = @{
                    EditionUID = @{ id=0x45bc; type='uint' };
                    EditionFlagHidden = @{ id=0x45bd; type='uint' };
                    EditionFlagDefault = @{ id=0x45db; type='uint' };
                    EditionFlagOrdered = @{ id=0x45dd; type='uint' };
                    ChapterAtom = @{ id=0xb6; type='container'; children = @{
                        ChapterUID = @{ id=0x73c4; type='uint' };
                        ChapterStringUID = @{ id=0x5654; type='8' };
                        ChapterTimeStart = @{ id=0x91; type='uint' };
                        ChapterTimeEnd = @{ id=0x92; type='uint' };
                        ChapterFlagHidden = @{ id=0x98; type='uint'; value=0 };
                        ChapterFlagEnabled = @{ id=0x4598; type='uint'; value=0 };
                        ChapterSegmentUID = @{ id=0x6e67; type='binary' };
                        ChapterSegmentEditionUID = @{ id=0x6ebc; type='uint' };
                        ChapterPhysicalEquiv = @{ id=0x63c3; type='uint' };
                        ChapterTrack = @{ id=0x8f; type='container'; children = @{
                            ChapterTrackNumber = @{ id=0x89; type='uint' };
                        }};
                        ChapterDisplay = @{ id=0x80; type='container'; children = @{
                            ChapString = @{ id=0x85; type='string' };
                            ChapLanguage = @{ id=0x437c; type='string'; value='eng' };
                            ChapCountry = @{ id=0x437e; type='string' };
                        }};
                        ChapProcess = @{ id=0x6944; type='container'; children = @{
                            ChapProcessCodecID = @{ id=0x6955; type='uint' };
                            ChapProcessPrivate = @{ id=0x450d; type='binary' };
                            ChapProcessCommand = @{ id=0x6911; type='container'; children = @{
                                ChapProcessTime = @{ id=0x6922; type='uint' };
                                ChapProcessData = @{ id=0x6933; type='binary' };
                            }}
                        }}
                    }}
                }}
            }};

            # Tagging
            Tags = @{ id=0x1254c367; type='container'; children = @{
                Tag = @{ id=0x7373; type='container'; children = @{
                    Targets = @{ id=0x63c0; type='container'; children = @{
                        TargetTypeValue = @{ id=0x68ca; type='uint' };
                        TargetType = @{ id=0x63ca; type='s' };
                        TagTrackUID = @{ id=0x63c5; type='uint'; value=0 };
                        TagEditionUID = @{ id=0x63c9; type='uint' };
                        TagChapterUID = @{ id=0x63c4; type='uint'; value=0 };
                        TagAttachmentUID = @{ id=0x63c6; type='uint'; value=0 };
                    }};
                    SimpleTag = @{ id=0x67c8; type='container'; children = @{
                        TagName = @{ id=0x45a3; type='string' };
                        TagLanguage = @{ id=0x447a; type='s' };
                        TagDefault = @{ id=0x4484; type='uint' };
                        TagString = @{ id=0x4487; type='string' };
                        TagBinary = @{ id=0x4485; type='binary' };
                    }}
                }}
            }}
        }}
    }

    $script:DTD += @{names=(flattenDTD $DTD); IDs=(flattenDTD $DTD -byID:$true)}
}

export-moduleMember -function parseMKV
