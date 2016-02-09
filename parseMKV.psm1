#requires -version 4
set-strictMode -version 4

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
    Stop parsing when /an/entry/path/ matches the regex pattern, case-insensitive, specify an empty string to disable

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

.PARAMETER printFilter
    Only elements with names matching the provided regexp or scriptblock will be printed.
    Scriptblock receives 'entry' as a parameter and should return a boolean value.
    By default 'SeekHead', 'EBML', 'Void' elements are skipped.
    Empty string = print everything.

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -print

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv'`

    $mkv.Tracks.Video | %{ 'Video: {0}x{1}, {2}' -f $_.Video.PixelWidth, $_.Video.PixelHeight, $_.CodecID }
    $isMultiAudio = $mkv.Tracks.Audio.Capacity -gt 1
    $mkv.Tracks.Audio | %{ $index=0 } { 'Audio{0}: {1}{2}' -f (++$index), $_.CodecID, $_.Audio.SamplingFrequency }

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv' -stopOn '/tracks/' -binarySizeLimit 0

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

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -print -printFilter { $args[0]._.type -eq 'string' }

    parseMKV 'c:\some\path\file.mkv' -print -printFilter { $args[0] -is [datetime] }

    parseMKV 'c:\some\path\file.mkv' -print -printFilter { param($e)
        $e._.name -match '^Chap(String|Lang|terTime)' -and $e._.closest('ChapterAtom').ChapterTimeStart.hours -ge 1
    }

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv'

    $DisplayWidth = $mkv._.find('DisplayWidth')
    $DisplayHeight = $mkv._.find('DisplayHeight')
    $VideoCodecID = $DisplayWidth._.closest('TrackEntry').CodecID

    $DisplayWxH = $mkv.Tracks.Video._.find('', '^Display[WH]') -join 'x'

    ($mkv._.find('ChapterTimeStart') | %{ $_._.displayString }) -join ", "

    $mkv._.find('ChapterAtom') | %{
        '{0:h\:mm\:ss}' -f $_._.find('ChapterTimeStart') +
        " - " +
        $_._.find('ChapString')
    }
#>

function parseMKV(
        [string] [parameter(mandatory)] [validateScript({test-path -literal $_})]
    $filepath,

        [string] [validateScript({'' -match $_ -or $true})]
    $stopOn,

        [string] [validateScript({'' -match $_ -or $true})]
    $skip = '^/Segment/(Cluster|Cue)', <# checked only after -stopOn #>

        [string] [validateSet('skip','read-when-printing','read','exhaustive-search')]
    $tags = 'read-when-printing',

        [int32] [validateRange(-1, [int32]::MaxValue)]
    $binarySizeLimit = 16,

        [switch]
    $keepStreamOpen,

        [switch]
    $print,

        [switch]
    $printRaw,

        [validateScript({($_ -is [string] -and ('' -match $_ -or $true)) -or $_ -is [scriptblock]})]
    $printFilter = '^(?!.*?/(SeekHead/|EBML/|Void\b))', <# string/scriptblock #>

        [scriptblock]
    $entryCallback
) {
    try {
        $stream = [IO.FileStream]::new(
            $filepath,
            [IO.FileMode]::open,
            [IO.FileAccess]::read,
            [IO.FileShare]::read,
            16, # by default read-ahead is 4096 and we don't need that after every seek
            [IO.FileOptions]::RandomAccess
        )
        $bin = [IO.BinaryReader] $stream
    } catch {
        throw $_
        return $null
    }

    if (!(test-path variable:script:DTD)) {
        init
    }
    $state = @{
        abort = $false # set when entryCallback returns 'abort'
        print = @{ tick=[datetime]::now.ticks }
        timecodeScale = $DTD.__names.TimecodeScale.value
    }
    # less ambiguous local alias
    $opt = @{
        stopOn = $stopOn
        skip = $skip + (&{
            if ($tags -eq 'skip' -or ($tags -eq 'read-when-printing' -and ![bool]$print)) {
                '|/Tags/'
            }
        })
        tags = $tags
        binarySizeLimit = $binarySizeLimit
        print = [bool]$print -or [bool]$printRaw
        printRaw = [bool]$printRaw
        printFilter = $printFilter
        entryCallback = $entryCallback
    }

    $header = readRootContainer 'EBML'

    if (!$state.abort) {
        $segment = readRootContainer 'Segment'
        $segment._.header = $header
    } else {
        $segment = $header
    }

    if ([bool]$keepStreamOpen) {
        $segment._.reader = $bin
    } else {
        $bin.close()
    }

    if ($opt.print) {
        if (!$state.print['omitLineFeed']) {
            $host.UI.writeLine()
        }
        if ($state.print['progress']) {
            write-progress $state.print.progress -completed
        }
    }

    $segment
}

function readRootContainer([string]$requiredID) {
    if ($stream.position -ge $stream.length) {
        return
    }

    $meta = readEntry @{ _=@{path='/'; level=-1; root=$null} }

    if (!$meta -or !$meta.ref -or $meta.type -ne 'container') {
        throw 'Not a container'
    }

    $container = $meta.root = $meta.ref
    $meta.remove('parent')

    if ($requiredID -and $meta.name -ne $requiredID) {
        throw "Expected '$requiredID' but got '$($meta.name)'"
    }
    if ($opt.entryCallback -and (& $opt.entryCallback $container) -eq 'abort') {
        $state.abort = $true;
        return $container
    }
    if ($opt.print) {
        printEntry $container
    }

    readChildren $container
    $container
}

function readChildren($container) {
    $stream.position = $container._.datapos
    $stopAt = $container._.datapos + $container._.size

    while ($stream.position -lt $stopAt -and !$state.abort) {

        $meta = readEntry $container
        if (!$meta) {
            break
        }

        $child = $meta.ref

        if ($opt.entryCallback -and (& $opt.entryCallback $child) -eq 'abort') {
            $state.abort = $true
            break
        }
        if ($meta['skipped']) {
            if (!$state['exhaustiveSearch']) {
                if ($opt.tags -ne 'skip' -and (locateTagsBlock $child)) {
                    continue
                }
                if ($opt.tags -ne 'exhaustive-search') {
                    $stream.position = $stopAt
                    break
                }
                $state.exhaustiveSearch = $true
            }
            if ($opt.print) {
                $silentSeconds = ([datetime]::now.ticks - $state.print.tick)/10000000
                if ($silentSeconds -gt 0.3) {
                    $done = $meta.pos / $stream.length
                    $state.print.progress = "Skipping $($meta.name) elements"
                    write-progress $state.print.progress `
                        -percentComplete ($done * 100) `
                        -secondsRemaining ($silentSeconds / $done - $silentSeconds + 1)
                }
            }
            continue
        }
        if ($meta.type -ne 'container') {
            continue
        }
        if (!$opt.print) {
            readChildren $child
            continue
        }
        if ($opt.printRaw) {
            printEntry $child
            readChildren $child
            continue
        }
        if ($state.print['postponed']) {
            readChildren $child
            continue
        }
        if ($meta.path -cmatch $printPostponed) {
            $state.print.postponed = $true
            readChildren $child
            printEntry $child
            printChildren $child -includeContainers
            $state.print.postponed = $false
        } else {
            printEntry $child
            readChildren $child
        }
    }

    if ($opt.print -and !$state.abort -and !$state.print['postponed']) {
        printChildren $container
    }
}

function readEntry($container) {
    # inlining because PowerShell's overhead for a simple function call
    # is bigger than the time to execute it

    function bakeTime($value=$value, $meta=$meta, [bool]$ms, [bool]$fps, [switch]$noScaling) {
        [uint64]$nanoseconds = if ([bool]$noScaling) { $value }
                               else { $value * $state.timecodeScale }
        $time = [TimeSpan]::new($nanoseconds / 100)
        if ($ms) {
            $fpsstr = if ($fps -and $container['TrackType'] -match '^(1|Video)$') {
                ', ' + (1000000000 / $value).toString('g5',$numberFormat) + ' fps'
            }
            $meta.displayString = ('{0:0}ms' -f $time.totalMilliseconds) + $fpsstr
        } else {
            $meta.displayString = '{0}{1}s ({2:hh\:mm\:ss\.fff})' -f `
                $time.totalSeconds.toString('n0',$numberFormat),
                (('.{0:000}' -f $time.milliseconds) -replace '\.000',''),
                $time
        }
        $meta.rawValue = $value
        $time
    }

    $meta = $script:meta.PSObject.copy()
    $meta.pos = $stream.position

    $buf = [byte[]]::new(8)
    $buf[0] = $_ = $bin.readByte()
    $meta.id = if ($_ -eq 0 -or $_ -eq 0xFF) {
            write-warning "BAD ID $_"
            -1
        } else {
            $len = 8 - [byte][Math]::floor([Math]::log($_)/[Math]::log(2))
            if ($len -eq 1) {
                $_
            } else {
                $bin.read($buf, 1, $len - 1) >$null
                [Array]::reverse($buf, 0, $len)
                [BitConverter]::ToUInt64($buf, 0)
            }
        }

    $info = $DTD.__IDs['{0:x}' -f $meta.id]

    $meta.name = if ($info) { $info.name } else { '?' }
    $meta.type = if ($info) { $info.type } else { '' }
    $meta.path = $container._.path + $meta.name + '/'*[int]($meta.type -eq 'container')

    $meta.size = $size = if ($info -and $info.contains('size')) {
            $info.size
        } else {
            $buf.clear()
            $buf[0] = $_ = $bin.readByte()
            if ($_ -eq 0 -or $_ -eq 0xFF) {
                write-warning "BAD SIZE $_"
                -1
            } else {
                $len = 8 - [byte][Math]::floor([Math]::log($_)/[Math]::log(2))
                $buf[0] = $_ = $_ -band -bnot (1 -shl (8-$len))
                if ($len -eq 1) {
                    $_
                } else {
                    $bin.read($buf, 1, $len - 1) >$null
                    [Array]::reverse($buf, 0, $len)
                    [BitConverter]::ToUInt64($buf, 0)
                }
            }
        }

    $meta.datapos = $stream.position

    if (!$info) {
        write-warning ("{0,8}: {1,8:x}`tUnknown EBML ID" -f $meta.pos, $meta.id)
        $stream.position += $size
        return $meta
    }

    if ($opt.stopOn -and $meta.path -match $opt.stopOn) {
        $stream.position = $meta.pos
        return $null
    }

    $meta.level = $container._.level + 1
    $meta.root = $container._.root
    $meta.parent = $container

    if ($opt.skip -and $meta.path -match $opt.skip) {
        $stream.position += $size
        $meta.ref = [ordered]@{ _=$meta }
        $meta.skipped = $true
        return $meta
    }

    if ($size) {
        switch ($meta.type) {
            'int' {
                if ($size -eq 1) {
                    $value = $bin.readSByte()
                } else {
                    $buf.clear()
                    $bin.read($buf, 0, $size) >$null
                    [Array]::reverse($buf, 0, $size)
                    $value = [BitConverter]::toInt64($buf, 0)
                    if ($size -lt 8) {
                        $value -= ([int64]1 -shl $size*8)
                    }
                }
            }
            'uint' {
                if ($size -eq 1) {
                    $value = $bin.readByte()
                } else {
                    $buf.clear()
                    $bin.read($buf, 0, $size) >$null
                    [Array]::reverse($buf, 0, $size)
                    $value = [BitConverter]::toUInt64($buf, 0)
                }
            }
            'float' {
                $buf = $bin.readBytes($size)
                [Array]::reverse($buf)
                switch ($size) {
                    4 { $value = [BitConverter]::toSingle($buf, 0) }
                    8 { $value = [BitConverter]::toDouble($buf, 0) }
                    10 { $value = decodeLongDouble $buf }
                    default {
                        write-warning "FLOAT should be 4, 8 or 10 bytes, got $size"
                        $value = 0.0
                    }
                }
            }
            'date' {
                if ($size -ne 8) {
                    write-warning "DATE should be 8 bytes, got $size"
                    $rawvalue = 0
                } else {
                    $buf = $bin.readBytes(8)
                    [Array]::reverse($buf)
                    $rawvalue = [BitConverter]::toInt64($buf,0)
                }
                $value = ([datetime]'2001-01-01T00:00:00.000Z').addTicks($rawvalue/100)
            }
            'string' {
                $value = [Text.Encoding]::UTF8.getString($bin.readBytes($size))
            }
            'binary' {
                $readSize = if ($opt.binarySizeLimit -lt 0) { $size }
                            else { [Math]::min($opt.binarySizeLimit,$size) }
                if ($readSize) {
                    $value = $bin.ReadBytes($readSize)
                    if ($meta.name -cmatch '\wUID$') {
                        $meta.displayString = bin2hex $value
                    }
                } else {
                    $value = [byte[]]::new(0)
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
    } elseif ($info.contains('value')) {
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

    # using explicit assignment to keep empty values that get lost in $var=if(...) {val1} else {val2}
    if ($typecast) { $result = $value -as $typecast } else { $result = $value }

    # cook the values
    switch -regex ($meta.path) {
        '/Info/TimecodeScale$' {
            $state.timecodeScale = $value
            if ($dur = $container['Duration']) {
                setEntryValue $dur (bakeTime $dur $dur._)
            }
        }
        '/Info/Duration$' {
            if ($container['TimecodeScale']) {
                $result = bakeTime
            }
        }
        '/(Cluster/Timecode|CuePoint/CueTime)$' {
            $result = bakeTime
        }
        '/CueTrackPositions/CueDuration$' {
            $result = bakeTime -ms:$true
        }
        '/ChapterAtom/ChapterTime(Start|End)$' {
            $result = [TimeSpan]::new($value / 100)
            $meta.displayString = '{0:hh\:mm\:ss\.fff}' -f $result
        }
        '/TrackEntry/Default(DecodedField)?Duration$' {
            $result = bakeTime -ms:$true -fps:$true -noScaling
        }
        '/TrackEntry/TrackType$' {
            if ($typestr = $DTD.__TrackTypes[[int]$result]) {
                $meta.rawValue = $result
                $result = $typestr
                addNamedChild $container._.parent $typestr $container
            }
            'DefaultDuration', 'DefaultDecodedFieldDuration' | %{
                if ($dur = $container[$_]) {
                    setEntryValue $dur (bakeTime $dur $dur._ -ms:$true -fps:$true -noScaling)
                }
            }
        }
    }

    $key = $meta.name

    # this single line consumes up to 50% of the entire processing time
    $meta.ref = add-member _ $meta -inputObject $result -passthru

    #inlining for speed: addNamedChild $container $key $entry
    $existing = $container[$key]
    if ($existing -eq $null) {
        $container[$key] = $meta.ref
    } elseif ($existing -is [Collections.ArrayList]) {
        $existing.add($meta.ref) >$null
    } else {
        $container[$key] = [Collections.ArrayList] @($existing, $meta.ref)
    }
    $meta
}

function locateTagsBlock($current) {
    $seg = $current._.closest('Segment')
    [uint64]$end = $seg._.datapos + $seg._.size

    $maxBackSteps = 4096
    $stepSize = 512

    if ($stream.position + 16*$current._.size + $maxBackSteps*$stepSize -gt $end) {
        # do nothing if the stream's end is near
        return
    }
    $IDs = 'Tags','Cluster','Cues' | %{
        $IDhex = $DTD.__names[$_].id.toString('X')
        if ($IDhex.length -band 1) { $IDhex = '0' + $IDhex }
        ($IDhex -replace '..', '-$0').substring(1)
    }

    foreach ($step in 1..$maxBackSteps) {
        $stream.position = $start = $end - $stepSize*$step
        $buf = $bin.readBytes($stepSize + 8*2) # current code supports max 8-byte id and size
        $haystack = [BitConverter]::toString($buf)

        # try locating Tags first but in case the last section is
        # Clusters or Cues assume there's no Tags anywhere and just report success
        # in order for readChildren to finish its job peacefully
        foreach ($IDhex in $IDs) {
            $idlen = ($IDhex.length+1)/3
            $idpos = $buf.length
            while ($idpos -gt 0) {
                $idpos = $haystack.lastIndexOf($IDhex, ($idpos-1)*3) / 3
                if ($idpos -lt 0) {
                    break
                }
                # try reading 'size'
                $sizepos = $idpos + $idlen
                $first = $buf[$sizepos]
                if ($first -eq 0 -or $first -eq 0xFF -or $sizepos+7 -ge $buf.length) {
                    break
                } else {
                    $sizelen = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
                    $buf[$sizepos] = $first = $first -band -bnot (1 -shl (8-$sizelen))
                    [Array]::reverse($buf, $sizepos, $sizelen)
                    foreach ($_ in ($sizepos+$sizelen)..($sizepos+7)) { $buf[$_] = 0 }
                    $size = [BitConverter]::ToUInt64($buf, $sizepos)

                    if ($start + $sizepos + $sizelen + $size -eq $end) {
                        $stream.position = $start + $idpos
                        return $true
                    }
                }
            }
        }
    }
    $stream.position = $current._.datapos + $current._.size
}

function addNamedChild($dict, [string]$key, $value) {
    $current = $dict[$key]
    if ($current -eq $null) {
        $dict[$key] = $value
    } elseif ($current -is [Collections.ArrayList]) {
        $current.add($value) >$null
    } else {
        $dict[$key] = [Collections.ArrayList] @($current, $value)
    }
}

function setEntryValue($entry, $value) {
    $meta = $entry._
    $raw = $entry.PSObject.copy(); $raw.PSObject.members.remove('_')
    $meta.rawValue = $raw
    $entry = add-member _ $meta -inputObject $value -passthru
    $entry._.parent[$meta.name] = $entry
    $entry
}

function bin2hex([byte[]]$value) {
    if ($value) { [BitConverter]::toString($value) -replace '-', '' }
    else { '' }
}

function decodeLongDouble([byte[]]$data) {
    # Converted from C# function
    # Original author: Nathan Baulch (nbaulch@bigpond.net.au)
    #   http://www.codeproject.com/Articles/6612/Interpreting-Intel-bit-Long-Double-Byte-Arrays
    # References:
    #   http://cch.loria.fr/documentation/IEEE754/numerical_comp_guide/ncg_math.doc.html
    #   http://groups.google.com/groups?selm=MPG.19a6985d4683f5d398a313%40news.microsoft.com

    if (!$data -or $data.count -lt 10) {
        return $null
    }

    [int16]$e = ($data[9] -band 0x7F) -shl 8 -bor $data[8]
    if (!$e) { return 0.0 } # subnormal, pseudo-denormal or zero

    [byte]$j = $data[7] -band 0x80
    if (!$j) { return $null }

    [int64]$f = $data[7] -band 0x7F
    foreach ($i in 6..0) {
        $f = $f -shl 8 -bor $data[$i]
    }

    [byte]$s = $data[9] -band 0x80

    if ($e -eq 0x7FFF) {
        if ($f) { return [double]::NaN }
        if (!$s) { return [double]::positiveInfinity }
        return [double]::negativeInfinity
    }

    $e -= 0x3FFF - 0x3FF
    if ($e -ge 0x7FF) { return $null } # outside the range of a double
    if ($e -lt -51) { return 0.0 } # too small to translate into subnormal

    $f = $f -shr 11

    if ($e -lt 0) { # too small for normal but big enough to represent as subnormal
        $f = ($f -bor 0x10000000000000) -shr (1 - $e)
        $e = 0
    }

    [byte[]]$new = [BitConverter]::getBytes($f)
    $new[7] = $s -bor ($e -shr 4)
    $new[6] = (($e -band 0x0F) -shl 4) -bor $new[6]

    [BitConverter]::toDouble($new, 0)
}

#####################################################################################################

function printChildren($container, [switch]$includeContainers) {
    $container.values.forEach({
        if ($_._.type -eq 'container' -and ![bool]$includeContainers) {
            return
        }
        if ($_ -is [Collections.ArrayList]) {
            $_.forEach({
                if (!$_._['printed']) {
                    printEntry $_
                    $_._.printed = $true
                }
            })
        } elseif (!$_._['printed']) {
            printEntry $_
            $_._.printed = $true
        }
    })
}

function printEntry($entry) {

    function xy2ratio([int]$x, [int]$y) {
        [int]$a = $x; [int]$b = $y
        while ($b -gt 0) {
            [int]$rem = $a % $b
            $a = $b
            $b = $rem
        }
        "$($x/$a):$($y/$a)"
    }

    $meta = $entry._
    if ($meta['skipped']) {
        return
    }
    if ($opt.printFilter -is [string]) {
        if (!($meta.path -match $opt.printFilter)) {
            return
        }
    } elseif ($opt.printFilter -is [scriptblock]) {
        if (!(& $opt.printFilter $entry)) {
            return
        }
    }

    $last = $state.print
    if ($last['progress']) {
        write-progress $last.progress -completed
        $last.progress = $null
    }
    $emptyBinary = $meta.type -eq 'binary' -and !$entry.length
    if ($emptyBinary -and $last['emptyBinary'] -and $last['path'] -eq $meta.path) {
        $last['skipped']++
        $host.UI.write('.')
        return
    }
    if ($last['path']) {
        if ($last['skipped']) {
            $host.UI.writeLine(8,0, " [$($last.skipped)]")
            $last.skipped = 0
        } elseif (!$last['omitLineFeed']) {
            $host.UI.writeLine()
        } else {
            $last['omitLineFeed'] = $false
        }
    }
    $last.path = $meta.path
    $last.tick = [datetime]::now.ticks
    $last.emptyBinary = $emptyBinary

    if (!$printRaw) {
      switch -regex ($meta.path) {
        '/TrackEntry/$' {
            $type = $entry.TrackType
            $oneOfKind = $entry._.parent[$type] -isnot [Collections.ArrayList]
            $flags = if ($entry['FlagForced'] -eq 1) { '!' } else { '' }
            $flags += @{ d='*'; d0=''; d1='+' }["d$($entry['FlagDefault'])"]
            $flags += if ($entry['FlagEnabled'] -eq 0) { '-' } else { '' }
            $host.UI.write('white', 0, ('  '*$entry._.level) +
                $type + ' ' + ($flags -replace '.$','$0 '))
            $host.UI.write('gray', 0, $entry.CodecID + ' ')
            $s = ''
            $alt = ''
            switch ($type) {
                'Video' {
                    $w = $entry.Video.PixelWidth
                    $h = $entry.Video.PixelHeight
                    $i = if ($entry.Video['FlagInterlaced'] -eq 1) { 'i' } else { '' }
                    $host.UI.write('yellow', 0, "${w}x$h$i ")

                    $dw = $entry.Video['DisplayWidth']; if (!$dw) { $dw = $w }
                    $dh = $entry.Video['DisplayHeight']; if (!$dh) { $dh = $h }
                    $DAR = xy2ratio $dw $dh
                    $SAR = xy2ratio $w $h
                    if ($SAR -eq $DAR) {
                        $SAR = ''
                    } else {
                        $DARden = $DAR -replace '^.+?:',''
                        $DAR = "DAR $DAR"
                        $PAR = xy2ratio ($dw*$h) ($w*$dh)
                        $SAR = ', orig ' + ($w / $h).toString('g4',$numberFormat) + ", PAR $PAR"
                    }
                    $host.UI.write('darkgray', 0, "($DAR or $(($dw/$dh).toString('g4',$numberFormat))$SAR) ")

                    $d = $entry['DefaultDuration']
                    if (!$d) { $d = $entry['DefaultDecodedFieldDuration'] }
                    $fps = if ($d) { ($d._.displayString -replace '^.+?, ', '') + ' ' } else { '' }
                    $host.UI.write('yellow', 0, $fps)
                }
                'Audio' {
                    $ch = $entry._.find('Channels')
                    if ($ch) { $s += "${ch}ch " }

                    $hz = $entry._.find('SamplingFrequency')
                    $hzOut = $entry._.find('OutputSamplingFrequency'); if (!$hzOut) { $hzOut = $hz }
                    if ($hzOut) { $s += ($hzOut/1000).toString($numberFormat) + 'kHz ' }
                    if ($hzOut -and $hzOut -ne $hz) { $s += '(SBR) ' }
                    $bits = $entry._.find('BitDepth')
                    if ($bits) { $s += "${bits}bit " }
                    $host.UI.write('yellow', 0, $s)
                }
            }
            $lng = "$($entry['Language'])" -replace 'und',''
            if (!$lng) { $lng = $DTD.__names.TrackEntry.children.Language.value }
            $name = $entry['Name']
            if ($lng) {
                if ($name) { $lng += '/' }
                $host.UI.write('darkgray', 0, $lng)
            }
            if ($name) {
                $host.UI.write('green', 0, $name + ' ')
            }
            return
        }
        '/ChapterAtom/$' {
            $enabled = if ($entry['ChapterFlagEnabled'] -ne 0) { 1 } else { 0 }
            $hidden = if ($entry['ChapterFlagHidden'] -eq 1) { 1 } else { 0 }
            $flags = if ($enabled) { '' } else { '!' }
            $flags += if ($hidden) { '-' } else { '' }
            $color = (1-$enabled) + 2*$hidden
            $host.UI.write(@('white','gray','darkgray')[$color], 0, ('  '*$entry._.level) + 'Chapter ')
            $host.UI.write(@('gray','gray','darkgray')[$color], 0, $entry.ChapterTimeStart._.displayString + ' ')
            $host.UI.write('darkgray', 0, ($flags -replace '.$', '$0 '))
            $entry['ChapterDisplay'] | %{ $i = 0 } {
                if ($i -gt 0) {
                    $host.UI.write('darkgray', 0, ' ')
                }
                $lng = $_['ChapLanguage']; if (!$lng) { $lng = $DTD.__names.ChapLanguage.value }
                if ($lng -and $lng -ne 'und') {
                    $host.UI.write('darkgray', 0, $lng + '/')
                }
                if ($_['ChapString']) {
                    $host.UI.write(@('green','gray','darkgray')[$color], 0, $_.ChapString)
                }
                $i++
            }
            return
        }
        '/EditionEntry/EditionFlag(Hidden|Default)$' {
            if ($entry -ne 1) {
                $last.omitLineFeed = $true
                return
            }
        }
        '/AttachedFile/FileName$' {
            $att = $meta.parent
            $host.UI.write('white', 0, ('  '*$att._.level) + 'AttachedFile ')
            $host.UI.write('green', 0, $entry + ' ')
            $host.UI.write('darkgray', 0, '['+$att.FileData._.size + ' bytes] ')
            $host.UI.write('darkgreen', 0, $att['FileDescription'])
            return
        }
        '/Tag/$' {
            $tracks = $meta.closest('Segment').Tracks.TrackEntry
            if ($tracks -isnot [Collections.ArrayList]) { $tracks = @($tracks) }
            $host.UI.write('white', 0, ('  '*$meta.level) + 'Tags ')

            $targets = if ($entry.Targets -is [Collections.ArrayList]) { $entry.Targets } else { @($entry.Targets) }
            $targets = $targets | %{ $comma = '' } {
                $UID = $_.TagTrackUID
                $track = $tracks.where({ $_.TrackUID -eq $UID }, 'first')
                if ($track) {
                    $track = $track[0]
                    $host.UI.write('gray', 0, $comma + '#' + $track.TrackNumber + ': ' + $track.TrackType)
                    if ($track['Name']) {
                        $host.UI.write('cyan', 0, ' (' + $track.Name + ')')
                    }
                }
                $comma = ', '
            }

            $host.UI.writeLine()
            $statsDelim = '  '*($entry._.level+1)

            $simpletags = if ($entry.SimpleTag -is [Collections.ArrayList]) { $entry.SimpleTag }
                          else { @($entry.SimpleTag) }
            foreach ($stag in $simpletags) {
                if ($stag.TagName.startsWith('_STATISTICS_')) {
                    continue
                }
                $stats = switch ($stag.TagName) {
                    'BPS' {
                        ($stag.TagString / 1000).toString('n0', $numberFormat); $alt = ' kbps' }
                    'DURATION' {
                        $stag.TagString -replace '.{6}$',''; $alt = '' }
                    'NUMBER_OF_FRAMES' {
                        ([uint64]$stag.TagString).toString('n0', $numberFormat); $alt = ' frames' }
                    'NUMBER_OF_BYTES' {
                        [uint64]$size = $stag.TagString
                        [uint64]$base = 0x10000000000
                        $alt = ''
                        @('TiB','GiB','MiB','KiB').where({
                            if ($size / $base -lt 1) {
                                $base = $base -shr 10
                            } else {
                                $alt = ($size / $base).toString('g3', $numberFormat) + ' ' + $_
                                $true
                            }
                        }, 'first') >$null
                        $s = $size.toString('n0', $numberFormat) + ' bytes'
                        if ($alt) { $alt; $alt = " ($s)" }
                        else { $s }
                    }
                }
                if ($stats) {
                    $host.UI.write('darkgray', 0, $statsDelim)
                    $host.UI.write(@('yellow','gray')[[int]!$alt], 0, $stats)
                    $host.UI.write('darkgray', 0, $alt)
                    $statsDelim = ', '
                    continue
                }
                $default = if ($stag['TagDefault'] -eq 1) { '*' } else { '' }
                $flags = $default + $stag.TagLanguage
                $host.UI.write('gray', 0, ('  '*$stag._.level) + $stag.TagName + ($flags -replace '^\*eng$',': '))
                if ($flags -ne '*eng') {
                    $host.UI.write('darkgray', 0, '/' + $flags + ': ')
                }
                if ($stag.contains('TagString')) {
                    $host.UI.write('darkcyan', 0, $stag.TagString)
                } elseif ($stag.contains('TagBinary')) {
                    $tb = $stag.TagBinary
                    if ($tb.length) {
                        $ellipsis = if ($tb.length -lt $tb._.size) { '...' } else { '' }
                        $host.UI.write('darkgray', 0, "[$($tb._.size) bytes] ")
                        $host.UI.write('darkgreen', 0, ((bin2hex $tb) -replace '(.{8})', '$1 ') + $ellipsis)
                    }
                }
                $host.UI.writeLine()
            }
            $host.UI.writeLine()
            return
        }
        '/Info/(DateUTC|(Muxing|Writing)App)$' {
            if ($meta.parent.MuxingApp -eq 'no_variable_data') {
                $last.omitLineFeed = $true
                return
            }
        }
        $printPretty {
            $last.omitLineFeed = $true
            return
        }
        '^/Segment/\w+/$' {
            $host.UI.writeLine()
        }
      }
    }

    $color = if ($meta.type -eq 'container') { 'white' } else { 'gray' }
    $host.UI.write($color, 0, ('  '*$meta.level) + $meta.name + ' ')

    $s = if ($meta.contains('displayString')) {
        $meta.displayString
    } elseif ($meta.type -eq 'binary') {
        if ($entry.length) {
            $ellipsis = if ($entry.length -lt $meta.size) { '...' } else { '' }
            "[$($meta.size) bytes] $((bin2hex $entry) -replace '(.{8})', '$1 ')$ellipsis"
        }
    } elseif ($meta.type -ne 'container') {
        "$entry"
    }
    $color = if ($meta.name -match 'UID$') { 'darkgray' }
             else { switch ($meta.type) { string { 'green' } binary { 'darkgray' } default { 'yellow' } } }
    $host.UI.write($color, 0, $s)
}

#####################################################################################################

function init {

    function flattenDTD([hashtable]$dict, [bool]$byID, [hashtable]$flat=@{}) {
        $dict.getEnumerator().forEach({
            $v = $_.value
            if ($byID) {
                $flat['{0:x}' -f $v.id] = $v
                $v.name = $_.key
            } else {
                $flat[$_.key] = $v
            }
            if ($v.contains('children')) {
                $flat = flattenDTD $v.children $byID $flat
            }
        })
        $flat
    }

    # postpone printing these small sections until all contained info is known
    $script:printPostponed = '/(Tracks|ChapterAtom|Tag)/$'
    $script:printPretty = `
        '/Segment/$|' +
        '/Info/(TimecodeScale|SegmentUID)$|' +
        '/Tracks/TrackEntry/(|' +
            'Video/(|(Pixel|Display)(Width|Height)|FlagInterlaced)|' +
            'Audio/(|(Output)?SamplingFrequency|Channels|BitDepth)|' +
            'Track(Number|UID|Type)|Codec(ID|Private)|Language|Name|DefaultDuration|MinCache|' +
            'Flag(Lacing|Default|Forced|Enabled)|CodecDecodeAll|MaxBlockAdditionID|TrackTimecodeScale' +
        ')$|' +
        '/Chapters/EditionEntry/(' +
            'EditionUID|' +
            'ChapterAtom/(|' +
                'Chapter(' +
                    'Display/(|Chap(String|Language|Country))|' +
                    'UID|Time(Start|End)|Flag(Hidden|Enabled)' +
                ')' +
            ')' +
        ')$|' +
        '/Attachments/AttachedFile/|' +
        '/Tags/Tag/'
    $script:numberFormat = [Globalization.CultureInfo]::InvariantCulture

    $script:meta = @{}

    add-member scriptMethod closest { param([string]$name, [string]$match)
        # find the closest parent matching 'name' or 'match' regexp ('name' takes precedence)
        $e = $this.ref
        do {
            if (($name -and $e._.name -eq $name) `
            -or ($match -and $e._.name -match $match)) {
                return $e
            }
            $e = $e._['parent']
        } until ($e -eq $null)
    } -inputObject $meta

    add-member scriptMethod find { param([string]$name, [string]$match)
        # find all nested children matching 'name' or 'match' regexp ('name' takes precedence)
        # returns: $null, a single object or a [Collections.ObjectModel.Collection`1]
        $results = {}.invoke()
        if ($this.type -ne 'container') {
            return $results
        }
        $this.ref.getEnumerator().forEach({
            $child = $_.value
            if ($child -eq $null) {
                return
            }
            $meta = $child._
            if (($name -and $meta.name -eq $name) `
            -or ($match -and $meta.name -match $match)) {
                $results.add($child)
            }
            if ($meta.type -eq 'container') {
                $meta.find($name,$match).forEach({
                    # skip aliases like Video <-> TrackEntry[0]
                    if ($results.indexOf($_) -eq -1) {
                        $results.add($_)
                    }
                })
            }
        })
        $results
    } -inputObject $meta

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
                    Language = @{ id=0x22b59c; type='string'; value='eng' };
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
                        ChapterStringUID = @{ id=0x5654; type='binary' };
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
                        TargetType = @{ id=0x63ca; type='string' };
                        TagTrackUID = @{ id=0x63c5; type='uint'; value=0 };
                        TagEditionUID = @{ id=0x63c9; type='uint' };
                        TagChapterUID = @{ id=0x63c4; type='uint'; value=0 };
                        TagAttachmentUID = @{ id=0x63c6; type='uint'; value=0 };
                    }};
                    SimpleTag = @{ id=0x67c8; type='container'; children = @{
                        TagName = @{ id=0x45a3; type='string' };
                        TagLanguage = @{ id=0x447a; type='string' };
                        TagDefault = @{ id=0x4484; type='uint' };
                        TagString = @{ id=0x4487; type='string' };
                        TagBinary = @{ id=0x4485; type='binary' };
                    }}
                }}
            }}
        }}
    }

    $names = flattenDTD $DTD
    $IDs = flattenDTD $DTD -byID:$true

    $DTD.__names = $names
    $DTD.__IDs = $IDs
    $DTD.__trackTypes = @{
        1='Video'
        2='Audio'
        0x10='Logo'
        0x11='Subtitle'
        0x12='Buttons'
        0x20='Control'
    }
}

export-moduleMember -function parseMKV
