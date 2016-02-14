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

.PARAMETER get
    Level-1 sections to get (and 'EBML'), an array of strings.
    Default: 'Info','Tracks','Chapters','Attachments' and additionally 'Tags' when printing.
    '*' means everything, *common' - the four above.

.PARAMETER exhaustiveSearch
    In case a block wasn't found automatically it will be searched
    by sequentially skipping all [usually Cluster] elements which may take a long time

.PARAMETER binarySizeLimit
    Do not autoread binary data bigger than this number of bytes, specify -1 for no limit

.PARAMETER entryCallback
    Code block to be called on each entry.
    Some time/date/tracktype values may yet be raw numbers because processing is
    guaranteed to occur only after all child elements of a container are read.
    Parameters: entry (with its metadata in _ property).
    Return value: 'abort' to stop all processing, otherwise ignored.
    //TODO: consider allowing to 'skip' current element.

.PARAMETER keepStreamOpen
    Leave the BinaryReader stream open in <result>._.reader

.PARAMETER print
    Pretty-print to the console.

.PARAMETER printRaw
    Print the element tree as is.

.PARAMETER showProgress
    Show the progress for long operations even when not printing.

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -print

.EXAMPLE
    parseMKV 'c:\some\path\file.mkv' -get Info -print

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv'`

    $mkv.Segment.Tracks.Video | %{
        'Video: {0}x{1}, {2}' -f $_.Video.PixelWidth, $_.Video.PixelHeight, $_.CodecID
    }
    $mkv.Segment.Tracks.Audio | %{ $index=0 } {
        'Audio{0}: {1} {2}Hz' -f (++$index), $_.CodecID, $_.Audio.SamplingFrequency
    }
    $audioTracksCount = $mkv.Segment.Tracks.Audio.count

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv' -stopOn '/tracks/' -binarySizeLimit 0

    $duration = $mkv.Segment.Info.Duration
    $duration = $mkv.Segment[1].Info[0].Duration # multi-segmented mkv!

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv' -keepStreamOpen -binarySizeLimit 0

    forEach ($att in $mkv.find('AttachedFile')) {
        $file = [IO.File]::create($att.FileName)
        $mkv.reader.baseStream.position = $att.FileData._.datapos
        $data = $mkv.reader.readBytes($att.FileData._.size)
        $file.write($data, 0, $data.length)
        $file.close()
    }
    $mkv.reader.close()

.EXAMPLE
    $mkv = parseMKV 'c:\some\path\file.mkv'

    $DisplayWidth = $mkv.find('DisplayWidth')
    $DisplayHeight = $mkv.find('DisplayHeight')
    $VideoCodecID = $DisplayWidth._.closest('TrackEntry').CodecID

    $DisplayWxH = $mkv.Segment.Tracks.Video._.find('', '^Display[WH]') -join 'x'

    $mkv.find('ChapterTimeStart')._.displayString -join ", "

    $mkv.find('FlagDefault') | ?{ $_ -eq 1 } | %{ $_._.parent|ft }

    forEach ($chapter in $mkv.find('ChapterAtom')) {
        '{0:h\:mm\:ss}' -f $chapter._.find('ChapterTimeStart') +
        " - " + $chapter._.find('ChapString')
    }

#>

function parseMKV(
        [string] [parameter(valueFromPipeline)]
                 [validateScript({ if ((test-path -literal $_) -or (test-path $_)) { $true }
                                   else { write-warning 'File not found'; throw } })]
    $filepath,

        [string[]]
        [validateSet('*',
                     '*common', <# comprises the next four #>
                     'Info','Tracks','Chapters','Attachments',
                     'Tags','Tags:whenPrinting',
                     'EBML', 'SeekHead','Cluster','Cues')]
    $get = @(
        '*common'
        'Tags:whenPrinting'
    ),

        [switch]
    $exhaustiveSearch,

        [int32] [validateRange(-1, [int32]::MaxValue)]
    $binarySizeLimit = 16,

        [switch]
    $keepStreamOpen,

        [switch]
    $print,

        [switch]
    $printRaw,

        [switch]
    $showProgress,

        [scriptblock]
    $entryCallback
) {

    if (!(test-path -literal $filepath)) {
        $filepath = "$(gi $filepath)"
    }
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
        timecodeScale = $DTD.Segment.Info.TimecodeScale._.value
    }
    # less ambiguous local alias
    $opt = @{
        get = if ('*common' -in $get) { @{Info='auto'; Tracks='auto'; Chapters='auto'; Attachments='auto'} }
              else { @{} }
        exhaustiveSearch = [bool]$exhaustiveSearch
        binarySizeLimit = $binarySizeLimit
        print = [bool]$print -or [bool]$printRaw
        printRaw = [bool]$printRaw
        showProgress = [bool]$showProgress -or [bool]$print -or [bool]$printRaw
        entryCallback = $entryCallback
    }
    $get | ?{ $_ -match '^\w+$' } | %{ $opt.get[$_] = $true }
    $opt.get['/EBML/'] = $opt.get['/Segment/'] = $opt.get.SeekHead = 'auto'
    if ($opt.print -and 'Tags:whenPrinting' -in $get) {
        $opt.get.Tags = $true
    }
    if ('*' -in $get) {
        $DTD, $DTD.Segment | %{
            $_.getEnumerator() | ?{ $_.name -ne '_' } | %{ $opt.get[$_.name] = 'auto' }
        }
    }

    $mkv = $dummyMeta.PSObject.copy()
    $mkv.PSObject.members.remove('closest')
    $mkv | add-member ([ordered]@{ path='/'; ref=$mkv; _=$mkv; DTD=$DTD})
    $mkv.EBML = [Collections.ArrayList]@()
    $mkv.Segment = [Collections.ArrayList]@()

    if ([bool]$keepStreamOpen) {
        $mkv | add-member reader $bin
    }

    while (!$state.abort -and $stream.position -lt $stream.length) {

        $meta = if (findNextRootContainer) { readEntry $mkv }

        if (!$meta -or !$meta['ref'] -or $meta['path'] -cnotmatch '^/(EBML|Segment)/$') {
            throw 'Cannot find EBML or Segment structure'
        }

        $container = $meta.root = $meta.ref
        $meta.level = 0
        $meta.root = $segment = $container
        $allSeekHeadsFound = $false

        if ($entryCallback -and (& $entryCallback $container) -eq 'abort') {
            $state.abort = $true;
            break
        }
        if ($opt.print) {
            printEntry $container
        }

        readChildren $container
    }

    if (![bool]$keepStreamOpen) {
        $bin.close()
    }
    if ($opt.print) {
        if ($state.print['needLineFeed']) {
            $host.UI.writeLine()
        }
        if ($state.print['progress']) {
            write-progress $state.print.progress -completed
        }
    }

    makeSingleParentsTransparent $mkv
    $mkv
}

#region MAIN

function findNextRootContainer {
    $toRead = 4 # EBML/Segment ID size
    $buf = [byte[]]::new($lookupChunkSize)
    forEach ($step in 1..128) {
        $bufsize = $bin.read($buf, 0, $toRead)
        $bufstr = [BitConverter]::toString($buf, 0, $bufsize)
        forEach ($id in <#EBML#>'1A-45-DF-A3', <#Segment#>'18-53-80-67') {
            $pos = $bufstr.indexOf($id)/3
            if ($pos -ge 0) {
                $stream.position -= $bufsize - $pos
                return $true
            }
        }
        $toRead = $buf.length
        $stream.position -= 4
    }
}

function readChildren($container) {
    $stream.position = $container._.datapos
    $stopAt = $container._.datapos + $container._.size
    $lastContainerServed = $false

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
        if (!$meta['skipped']) {
            if ($meta.type -ne 'container') {
                continue
            }
            if (!$opt.print -or $state.print['postponed']) {
                readChildren $child
            } elseif ($meta.path -cnotmatch $printPostponed -or $opt.printRaw) {
                printEntry $child
                readChildren $child
            } elseif ($matches) {
                $state.print.postponed = $true
                readChildren $child
                printEntry $child
                printChildren $child -includeContainers
                $state.print.postponed = $false
            }
            continue
        }
        if ($lastContainerServed -or $meta.name -eq 'Void') {
            continue
        }
        if ($segment['SeekHead']) {
            if (!($requestedSections = $opt.get.getEnumerator().where({ $_.value -eq $true }))) {
                $stream.position = $stopAt
                break
            }
            $pos = $segment._.datapos + $segment._.size
            forEach ($section in $requestedSections.name) {
                $p = $segment.SeekHead.named[$section]
                if (!$p -and !$allSeekHeadsFound) {
                    $allSeekHeadsFound = $true
                    if ($segment.SeekHead.named['SeekHead']) {
                        processSeekHead -findAll
                        $p = $segment.SeekHead.named[$section]
                    }
                }
                if ($p -lt $pos -and $p -gt $meta.datapos) {
                    $pos = $p
                }
            }
            $stream.position = $pos
            continue
        }
        if ($meta.name -eq 'Cluster' -and !$opt.get['Cluster']) {
            # here we don't need clusters and we don't have SeekHead
            # so in case more explicitly requested sections are needed
            # we'll try locating them at the end of the file
            if (($opt['exhaustiveSearch'] -or ($opt.get.values -eq $true)) -and (locateLastContainer)) {
                $lastContainerServed = $true
                continue
            }
            if (!$opt['exhaustiveSearch']) {
                $stream.position = $stopAt
                break
            }
        }
        if ($opt.showProgress -and ([datetime]::now.ticks - $state.print['progresstick'] -ge 1000000)) {
            showProgressIfStuck
        }
    }

    if ($container._.name -eq 'SeekHead') {
        processSeekHead $container
    }

    makeSingleParentsTransparent $container

    if ($opt.print -and !$state.abort -and !$state.print['postponed']) {
        printChildren $container
    } elseif ($opt.showProgress -and ([datetime]::now.ticks - $state.print['progresstick'] -ge 1000000)) {
        showProgressIfStuck
    }
}

function makeSingleParentsTransparent($container) {
    # make single container's properties directly enumerable
    # thus allowing to type $mkv.Segment.Info.SegmentUID without [0]'s
    forEach ($child in $container.getEnumerator()) {
        if ($child.value -is [Collections.ArrayList] `
        -and $child.value.count -eq 1 `
        -and $child.value[0]._.type -ceq 'container' `
        -and $child.value[0].count -gt 0) {
            add-member ([ordered]@{} + $child.value[0]) -inputObject $child.value
        }
    }
}

function readEntry($container) {

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

    # inlining because PowerShell's overhead for a simple function call
    # is bigger than the time to execute it

    $meta = $dummyMeta.PSObject.copy()
    $meta.pos = $stream.position

    $VINT = [byte[]]::new(8)
    $VINT[0] = $first = $bin.readByte()
    $meta.id =
        if ($first -eq 0 -or $first -eq 0xFF) {
            -1
        } elseif ($first -ge 0x80) {
            $first
        } elseif ($first -ge 0x40) {
            [int]$first -shl 8 -bor $bin.readByte()
        } else {
            $len = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
            $bin.read($VINT, 1, $len - 1) >$null
            [Array]::reverse($VINT, 0, $len)
            [BitConverter]::toUInt64($VINT, 0)
        }

    $idhex = '{0:x}' -f $meta.id
    if (!($info = $DTD._.globalIDs[$idhex])) {
        $info = $DTD
        forEach ($subpath in ($container._.path.substring(1) -split '/')) {
            if ($subpath -and (!$info._['recursiveNesting'] -or $subpath -ne $info._.name)) {
                $info = $info[$subpath]
            }
        }
        $info = $info._.IDs[$idhex]
    }
    if ($info) {
        $info = $info._
        $meta.name = $info.name
        $meta.type = $info.type
    } else {
        $meta.name = '?'
        $meta.type = 'binary'
        $info = @{}
    }

    $meta.path = $container._.path + $meta.name + '/'*[int]($meta.type -eq 'container')

    $meta.size = $size =
        if ($info -and $info.contains('size')) {
            $info.size
        } else {
            $VINT.clear()
            $VINT[0] = $first = $bin.readByte()
            if ($first -ge 0x80) {
                $first -band 0x7F
            } elseif ($first -ge 0x40) {
                ([int]$first -band 0x3F) -shl 8 -bor $bin.readByte()
            } else {
                $len = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
                $VINT[0] = $first -band -bnot (1 -shl (8-$len))
                $bin.read($VINT, 1, $len - 1) >$null
                [Array]::reverse($VINT, 0, $len)
                [BitConverter]::toUInt64($VINT, 0)
            }
        }

    $meta.datapos = $stream.position

    if (!$info) {
        $stream.position += $size
        return $meta
    }

    $meta.level = $container._['level'] + 1
    $meta.root = $container._['root']
    $meta.parent = $container

    if (($meta.path -match '^/.*?/(.+?)/' -or $meta.name -eq 'Void') -and !$opt.get[$matches[1]]) {
        $stream.position += $size
        $meta.ref = [ordered]@{ _=$meta }
        $meta.skipped = $true
        return $meta
    }

    if ($meta.type -ceq 'container') {
        $meta.ref = $result = $dummyContainer.PSObject.copy()
        $result._ = $meta
    } else {
        if ($size) {
            switch ($meta.type) {
                'int' {
                    if ($size -eq 1) {
                        $value = $bin.readSByte()
                    } else {
                        $VINT.clear()
                        $bin.read($VINT, 0, $size) >$null
                        [Array]::reverse($VINT, 0, $size)
                        $value = [BitConverter]::toInt64($VINT, 0)
                        if ($size -lt 8) {
                            $value -= ([int64]1 -shl $size*8)
                        }
                    }
                }
                'uint' {
                    switch ($size) {
                        1 { $value = $bin.readByte() }
                        2 { $value = [int]$bin.readByte() -shl 8 -bor $bin.readByte() }
                        default {
                            $VINT.clear()
                            $bin.read($VINT, 0, $size) >$null
                            [Array]::reverse($VINT, 0, $size)
                            $value = [BitConverter]::toUInt64($VINT, 0)
                        }
                    }
                }
                'float' {
                    $buf = $bin.readBytes($size)
                    [Array]::reverse($buf)
                    $value = switch ($size) {
                        4 { [BitConverter]::toSingle($buf, 0) }
                        8 { [BitConverter]::toDouble($buf, 0) }
                        10 { decodeLongDouble $buf }
                        default {
                            write-warning "FLOAT should be 4, 8 or 10 bytes, got $size"
                            0.0
                        }
                    }
                }
                'date' {
                    $rawvalue = if ($size -ne 8) {
                        write-warning "DATE should be 8 bytes, got $size"
                        0
                    } else {
                        $bin.read($VINT, 0, 8) >$null
                        [Array]::reverse($VINT)
                        [BitConverter]::toInt64($VINT,0)
                    }
                    $value = ([datetime]'2001-01-01T00:00:00.000Z').addTicks($rawvalue/100)
                }
                'string' {
                    $value = [Text.Encoding]::UTF8.getString($bin.readBytes($size))
                }
                'binary' {
                    $readSize = if ($opt.binarySizeLimit -lt 0 -or $meta.name -eq 'SeekID') { $size }
                                else { [Math]::min($opt.binarySizeLimit, $size) }
                    if ($readSize) {
                        $value = $bin.readBytes($readSize)

                        if ($meta.name -cmatch '\wUID$') {
                            $meta.displayString = bin2hex $value
                        }
                        elseif ($meta.name -eq '?') {
                            $s = [Text.Encoding]::UTF8.getString($value)
                            if ($s -cmatch '^[\x20-\x7F]+$') {
                                $meta.displayString =
                                    [BitConverter]::toString($value, 0,
                                                             [Math]::min(16,$value.length)) +
                                    @('','...')[[int]($readSize -gt 16)] +
                                    " possible ASCII string: $s"
                            }
                        }
                    } else {
                        $value = [byte[]]::new(0)
                    }
                }
            }
        } elseif ($info.contains('value')) {
            $value = $info.value
        } else {
            switch ($meta.type) {
                'int'       { $value = 0 }
                'uint'      { $value = 0 }
                'float'     { $value = 0.0 }
                'string'    { $value = '' }
                'binary'    { $value = [byte[]]::new(0) }
            }
        }

        $typecast = switch ($meta.type) {
            'int'  { if ($size -le 4) { [int32] } else { [int64] } }
            'uint' { if ($size -le 4) { [uint32] } else { [uint64] } }
            'float' { if ($size -eq 4) { [single] } else { [double] } }
        }

        # using explicit assignment to keep empty values that get lost in $var=if....
        if ($typecast) {
            $result = $value -as $typecast
        } else {
            $result = $value
        }

        # cook the values
        switch -regex ($meta.path) {
            '/Info/TimecodeScale$' {
                $state.timecodeScale = $value
                if ($dur = $container['Duration']) {
                    setEntryValue $dur (bakeTime $dur $dur._)
                }
            }
            '/Info/Duration$' {
                $result = bakeTime
            }
            '/(Cluster/Timecode|CuePoint/CueTime)$' {
                $result = bakeTime
            }
            '/(CueTrackPositions/CueDuration|BlockGroup/BlockDuration)$' {
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
                if ($value = $DTD._.trackTypes[[int]$result]) {
                    $meta.rawValue = $result
                    $result = $value
                    $tracks = $container._.parent
                    if ($existing = $tracks[$value]) {
                        $existing.add($container) >$null
                    } else {
                        $tracks[$value] = [Collections.ArrayList]@($container)
                    }
                }
                'DefaultDuration', 'DefaultDecodedFieldDuration' | %{
                    if ($dur = $container[$_]) {
                        setEntryValue $dur (bakeTime $dur $dur._ -ms:$true -fps:$true -noScaling)
                    }
                }
            }
        }
        # this single line consumes up to 50% of the entire processing time
        $meta.ref = add-member _ $meta -inputObject $result -passthru
    }
    $stream.position = $meta.datapos + $size

    $key = $meta.name
    $existing = $container[$key]
    if ($existing -eq $null) {
        if ($info['multiple']) {
            $container[$key] = [Collections.ArrayList] @(,$meta.ref)
        } else {
            $container[$key] = $meta.ref
        }
    } elseif ($existing -is [Collections.ArrayList]) {
        $existing.add($meta.ref) >$null
    } else { # should never happen according to DTD but just in case
        $container[$key] = [Collections.ArrayList] @($existing, $meta.ref)
    }
    $meta
}

function locateLastContainer {
    [uint64]$end = $segment._.datapos + $segment._.size

    $maxBackSteps = [int]0x100000 / $lookupChunkSize # max 1MB

    if ($stream.position + 16*$meta.size + $maxBackSteps*$lookupChunkSize -gt $end) {
        # do nothing if the stream's end is near
        return
    }

    $vint = [byte[]]::new(8)
    $IDs = 'Tags','SeekHead','Cluster','Cues','Chapters','Attachments','Tracks','Info' | %{
        $IDhex = $DTD.Segment[$_]._.id.toString('X')
        if ($IDhex.length -band 1) { $IDhex = '0' + $IDhex }
        ($IDhex -replace '..', '-$0').substring(1)
    }
    $last = $end

    forEach ($step in 1..$maxBackSteps) {
        $stream.position = $start = $end - $lookupChunkSize*$step
        $buf = $bin.readBytes($lookupChunkSize + 8*2) # max 8-byte id and size
        $haystack = [BitConverter]::toString($buf)

        # try locating Tags first but in case the last section is
        # Clusters or Cues assume there's no Tags anywhere and just report success
        # in order for readChildren to finish its job peacefully
        forEach ($IDhex in $IDs) {
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
                if ($first -eq 0 -or $first -eq 0xFF) {
                    continue
                }
                $sizelen = 8 - [byte][Math]::floor([Math]::log($first)/[Math]::log(2))
                if ($sizepos + $sizelen -ge $buf.length) {
                    continue
                }
                $first = $first -band -bnot (1 -shl (8-$sizelen))
                $size = if ($sizelen -eq 1) {
                        $first
                    } else {
                        $vint.clear()
                        $vint[0] = $first
                        [Buffer]::blockCopy($buf, $sizepos+1, $vint, 1, $sizelen-1)
                        [Array]::reverse($vint, 0, $sizelen)
                        [BitConverter]::toUInt64($vint, 0)
                    }
                if ($start + $sizepos + $sizelen + $size -ne $last) {
                    continue
                }
                $section = $DTD.Segment._.IDs[$IDhex -replace '-','']
                if ($section -and $opt.get[$section._.name]) {
                    $stream.position = $start + $idpos
                    return $true
                }
                if ($last -eq $end) {
                    $last = $start + $idpos
                }
            }
        }
    }
    $stream.position = if ($last -ne $end) { $last } else { $meta.datapos + $meta.size }
    return $last -ne $end
}

function processSeekHead($SeekHead = $segment.SeekHead, [switch]$findAll) {
    $SeekHead, $segment.SeekHead | %{
        if (!$_.PSObject.properties['named']) {
            add-member named @{} -inputObject $_
        }
    }

    $savedPos = $stream.position
    $moreHeads = [Collections.ArrayList] @()

    forEach ($seek in $SeekHead.Seek) {
        if ($section = $DTD.Segment._.IDs[(bin2hex $seek.SeekID)]) {
            $pos = $segment._.datapos + $seek.SeekPosition
            if ($section._.name -eq 'SeekHead') {
                if (!$moreHeads.contains($pos)) {
                    $moreHeads.add($pos) >$null
                }
            } else {
                $SeekHead.named, $segment.SeekHead.named | %{ $_[$section._.name] = $pos }
            }
        }
    }

    if ([bool]$findAll) {
        forEach ($pos in $moreHeads) {
            $stream.position = $pos
            if ($meta = readEntry $segment) {
                readChildren $meta.ref
            }
        }
        $stream.position = $savedPos
    }
}

#endregion
#region UTILITIES

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
    forEach ($i in 6..0) {
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

#endregion
#region PRINT

function printChildren($container, [switch]$includeContainers) {
    $printed = @{}
    $list = {0}.invoke()
    forEach ($child in $container.values) {
        if ($child._.type -eq 'container' -and ![bool]$includeContainers) {
            continue
        }
        if ($child -is [Collections.ArrayList]) {
            $toPrint = $child
        } else {
            $list[0] = $child
            $toPrint = $list
        }
        forEach ($entry in $toPrint) {
            $hash = [Runtime.CompilerServices.RuntimeHelpers]::getHashCode($entry)
            if (!$printed[$hash] -and !$entry._['skipped']) {
                printEntry $entry
                $printed[$hash] = $true
            }
        }
    }
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

    function prettySize([uint64]$size) {
        [uint64]$base = 0x10000000000
        $s = $alt = ''
        @('TiB','GiB','MiB','KiB').where({
            if ($size / $base -lt 1) {
                $base = $base -shr 10
            } else {
                $alt = ($size / $base).toString('g3', $numberFormat) + ' ' + $_
                $true
            }
        }, 'first') >$null
        $s = $size.toString('n0', $numberFormat) + ' bytes'
        if ($alt) { $alt, " ($s)" } else { $s, '' }
    }

    function printSimpleTags($entry) {
        $statsDelim = '  '*($entry._.level+1)
        forEach ($stag in $entry.SimpleTag) {
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
                    $s, $alt = prettySize $stag.TagString
                    $s
                }
            }
            if ($stats) {
                $host.UI.write($colors.dim, 0, $statsDelim)
                $host.UI.write($colors[@('value','normal')[[int]!$alt]], 0, $stats)
                $host.UI.write($colors.dim, 0, $alt)
                $statsDelim = ', '
                continue
            }
            $default = if ($stag['TagDefault'] -eq 1) { '*' } else { '' }
            $flags = $default + $stag['TagLanguage']
            $host.UI.write($colors.normal, 0,
                ('  '*$stag._.level) + $stag.TagName + ($flags -replace '^\*eng$',': '))
            $host.UI.write($colors.dim, 0, ("/$flags" -replace '/(\*eng)?$','') + ': ')
            if ($stag.contains('TagString')) {
                $host.UI.write($colors.stringdim2, 0, $stag.TagString)
            } elseif ($stag.contains('TagBinary')) {
                $tb = $stag.TagBinary
                if ($tb.length) {
                    $ellipsis = if ($tb.length -lt $tb._.size) { '...' } else { '' }
                    $host.UI.write($colors.dim, 0, "[$($tb._.size) bytes] ")
                    $host.UI.write($colors.stringdim2, 0,
                        ((bin2hex $tb) -replace '(.{8})', '$1 ') + $ellipsis)
                }
            }
            $host.UI.writeLine()

            if ($stag['SimpleTag']) {
                printSimpleTags $stag
            }
        }
    }

    function listTracksFor([string[]]$IDs, [string]$IDname) {
        $tracks = $segment['Tracks']
        if (!$tracks) {
            return
        }
        $comma = ''
        forEach ($ID in $IDs) {
            if ($track = $tracks.TrackEntry.where({ $_[$IDname] -eq $ID }, 'first')) {
                $track = $track[0]
                $host.UI.write($colors.normal, 0,
                    $comma + '#' + $track.TrackNumber + ': ' + $track.TrackType)
                if ($track['Name']) {
                    $host.UI.write($colors.reference, 0, " ($($track.Name))")
                }
                $comma = ', '
            }
        }
    }

    $meta = $entry._
    if ($meta['skipped']) {
        return
    }

    $last = $state.print
    if ($last['progress']) {
        write-progress $last.progress -completed
        $last.progress = $null
    }
    $emptyBinary = $meta.type -eq 'binary' -and !$entry.length
    if ($emptyBinary -and $last['emptyBinary'] -and $last['path'] -eq $meta.path) {
        $last['skipped']++
        $last['skippedSize'] += $meta.size
        return
    }
    if ($last['path']) {
        if ($last['skipped']) {
            $host.UI.writeLine($colors.dim, 0,
                " [$($last.skipped) entries skipped, $((prettySize $last.skippedSize) -join '')]")
            $last.skipped = $last.skippedSize = 0
        } elseif ($last['needLineFeed']) {
            $host.UI.writeLine()
        } else {
            $last['needLineFeed'] = $true
        }
    }
    $last.path = $meta.path
    $last.tick = [datetime]::now.ticks
    $last.emptyBinary = $emptyBinary

    $indent = '  '*$meta.level

    if (!$opt.printRaw) {
      $last['needLineFeed'] = $false
      switch -regex ($meta.path) {
        '^/Segment/$' {
            if (($i = $meta.parent.Segment.count) -gt 1) {
                $host.UI.write($colors.container, 0, "`n${indent}Segment #$i")
            }
        }
        '/TrackEntry/$' {
            $type = $entry.TrackType
            $flags = if ($entry['FlagForced'] -eq 1) { '!' } else { '' }
            $flags += if ($entry['FlagDefault'] -eq 1) { '*' }
            $flags += if ($entry['FlagEnabled'] -eq 0) { '-' }

            $host.UI.write($colors.container, 0, "$indent$type $($flags -replace '.$','$0 ')")
            $host.UI.write($colors.normal, 0, $entry.CodecID + ' ')

            $s = $alt = ''
            switch ($type) {
                'Video' {
                    $w = $entry.Video.PixelWidth
                    $h = $entry.Video.PixelHeight
                    $i = if ($entry.Video['FlagInterlaced'] -eq 1) { 'i' } else { '' }
                    $host.UI.write($colors.value, 0, "${w}x$h$i ")

                    $dw = $entry.Video['DisplayWidth']; if (!$dw) { $dw = $w }
                    $dh = $entry.Video['DisplayHeight']; if (!$dh) { $dh = $h }
                    $DAR = xy2ratio $dw $dh
                    $SAR = xy2ratio $w $h
                    if ($SAR -eq $DAR) {
                        $SAR = ''
                    } else {
                        $DARden = ($DAR -split ':')[-1]
                        $DAR = "DAR $DAR"
                        $PAR = xy2ratio ($dw*$h) ($w*$dh)
                        $SAR = ', orig ' + ($w / $h).toString('g4',$numberFormat) + ", PAR $PAR"
                    }
                    $host.UI.write($colors.dim, 0, "($DAR or $(($dw/$dh).toString('g4',$numberFormat))$SAR) ")

                    $d = $entry['DefaultDuration']
                    if (!$d) { $d = $entry['DefaultDecodedFieldDuration'] }
                    $fps = if ($d) { ($d._.displayString -replace '^.+?, ', '') + ' ' } else { '' }
                    $host.UI.write($colors.value, 0, $fps)
                }
                'Audio' {
                    $s += if ($ch = $meta.find('Channels')) { "${ch}ch " }
                    $hz = $meta.find('SamplingFrequency')
                    if (!($hzOut = $meta.find('OutputSamplingFrequency'))) { $hzOut = $hz }
                    $s += if ($hzOut) { ($hzOut/1000).toString($numberFormat) + 'kHz ' }
                    $s += if ($hzOut -and $hzOut -ne $hz) { '(SBR) ' }
                    $s += if ($bits = $meta.find('BitDepth')) { "${bits}bit " }
                    $host.UI.write($colors.value, 0, $s)
                }
            }
            $lng = "$($entry['Language'])" -replace 'und',''
            if (!$lng) { $lng = $DTD.Segment.Tracks.TrackEntry.Language._.value }
            $name = $entry['Name']
            if ($lng) {
                $host.UI.write($colors.bold, 0, $lng)
                if ($name) { $host.UI.write($colors.dim, 0, '/') }
            }
            if ($name) {
                $host.UI.write($colors.string, 0, $name + ' ')
            }
            $host.UI.writeLine()
            return
        }
        '/ChapterAtom/$' {
            $enabled = if ($entry['ChapterFlagEnabled'] -ne 0) { 1 } else { 0 }
            $hidden = if ($entry['ChapterFlagHidden'] -eq 1) { 1 } else { 0 }
            $flags = if ($enabled) { '' } else { '?' }
            $flags += if ($hidden) { '-' }
            $color = (1-$enabled) + 2*$hidden
            $host.UI.write($colors[@('container','normal','dim')[$color]], 0,
                "${indent}Chapter ")
            $host.UI.write($colors[@('normal','normal','dim')[$color]], 0,
                $entry.ChapterTimeStart._.displayString + ' ')
            $host.UI.write($colors.dim, 0,
                ($flags -replace '.$', '$0 '))
            forEach ($display in [array]$entry['ChapterDisplay']) {
                if ($display -ne $entry.ChapterDisplay[0]) {
                    $host.UI.write($colors.dim, 0, ' ')
                }
                $lng = $display['ChapLanguage']
                if (!$lng) { $lng = $DTD.Segment.Chapters.ChapterDisplay.ChapLanguage._.value }
                if ($lng -and $lng -ne 'und') {
                    $host.UI.write($colors.dim, 0, $lng.trim() + '/')
                }
                if ($display['ChapString']) {
                    $host.UI.write($colors[@('string','normal','dim')[$color]], 0, $display.ChapString)
                }
            }
            $host.UI.writeLine()
            if ($UID = $entry['ChapterSegmentUID']) {
                if ($end = $entry['ChapterTimeEnd']) {
                    $s = "${indent}        $($end._.displayString) "
                } else {
                    $s = "${indent}    "
                }
                $host.UI.write($colors.normal, 0, $s)
                $host.UI.writeLine($colors.dim, 0, "UID: $(bin2hex $UID)")
            }
            return
        }
        '/EditionEntry/$' {
            $flags = 'Ordered','Default','Hidden' | %{
                @('',$_.toLower())[[int]($entry["EditionFlag$_"] -eq 1)]
            }
            $host.UI.write($colors.container, 0, "${indent}Edition ")
            if (($flags -join '')) {
                $host.UI.write($colors.value, 0, $flags)
            }
            $host.UI.writeLine()
            return
        }
        '/AttachedFile/FileName$' {
            $att = $meta.parent
            $host.UI.write($colors.container, 0, ('  '*$att._.level) + 'AttachedFile ')
            $host.UI.write($colors.string, 0, $entry + ' ')
            $s, $alt = prettySize $att.FileData._.size
            $host.UI.write($colors[@('value','dim')[[int]!$alt]], 0, $s)
            $host.UI.write($colors.dim, 0, $alt)
            $host.UI.writeLine($colors.stringdim, 0, $att['FileDescription'])
            return
        }
        '/Tag/$' {
            $host.UI.write($colors.container, 0, "${indent}Tags ")
            listTracksFor $entry.Targets['TagTrackUID'] 'TrackUID'
            $host.UI.writeLine()
            printSimpleTags $entry
            $host.UI.writeLine("`n")
            return
        }
        '/CuePoint/$' {
            $cueTime = $entry.CueTime._.displayString -split ' '
            foreach ($cue in $entry.CueTrackPositions) {
                $host.UI.write($colors.container, 0, "${indent}Cue: ")
                $host.UI.write($colors.normal, 0, 'track ')
                $host.UI.write($colors.reference, 0, "$($cue.CueTrack) ")
                $host.UI.write($colors.dim, 0, $cueTime[0] + ' ')
                $host.UI.write($colors.value, 0, $cueTime[1] + ' ')
                $host.UI.write($colors.normal, 0, '-> ' + $cue.CueClusterPosition +
                    ($cue['CueRelativePosition'] -replace '^.',':$0') + "`t")
                listTracksFor @($cue.CueTrack) 'TrackNumber'
                $host.UI.writeLine()
            }
            $host.UI.writeLine()
            return
        }
        '/Info/(DateUTC|(Muxing|Writing)App)$' {
            if ($meta.parent['MuxingApp'] -eq 'no_variable_data') {
                return
            }
        }
        $printPretty {
            return
        }
        '^/Segment/\w+/$' {
            $host.UI.writeLine()
        }
      }
    }

    $color = if ($meta.type -eq 'container') { 'container' } else { 'normal' }
    $host.UI.write($colors[$color], 0, "$indent$($meta.name) ")

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
    $color = if ($meta.name -match 'UID$') { 'dim' }
             else { switch ($meta.type) { string { 'string' } binary { 'dim' } default { 'value' } } }
    $host.UI.write($colors[$color], 0, $s)
    $last.needLineFeed = $true
}

function showProgressIfStuck {
    $tick = [datetime]::now.ticks
    <# after 0.5sec of silence #>
    if ($tick - $state.print.tick -lt 5000000) {
        return
    }
    $state.print.progresstick = $tick
    if ($meta.path -match '/Cluster/') {
        $section = $segment
    } else {
        $section = $meta.closest('','/Segment/\w+/$')
    }
    $done = ($meta.pos - $section._.datapos) / $section._.size
    <# and update remaining time every 1sec #>
    if (!$state.print['progress'] -or $tick - $state.print['progressmsgtick'] -ge 10000000) {
        $silentSeconds = ($tick - $state.print.tick)/10000000
        $remain = $silentSeconds / $done - $silentSeconds + 0.5
        <# smooth-average the remaining time #>
        $state.print.progressremain =
            if (!$state.print['progress']) { $remain }
            else { ($state.print.progressremain + $remain) / 2 }
        $action = @('Reading', 'Skipping')[!!$meta['skipped']]
        <# show level-1 section name to avoid flicker of alternate subcontainers #>
        $state.print.progress = "$action $($meta.path -replace '^/\w+/(\w+).*','$1') elements..."
        $state.print.progressmsgtick = $tick
    }
    write-progress $state.print.progress `
        -percentComplete ($done * 100) `
        -secondsRemaining ([Math]::min($state.print.progressremain, [int32]::maxValue))
}

#endregion
#region INIT

function init {

    function addReverseMapping([hashtable]$container) {

        $meta = $container._
        $meta.IDs = @{}

        if ($meta['recursiveNesting']) {
            $meta.IDs['{0:x}' -f $meta.id] = $container
        }

        forEach ($child in $container.getEnumerator()) {
            if ($child.key -ne '_') {
                $v = $child.value
                $v._.name = $child.key
                $id = '{0:x}' -f $v._.id
                $meta.IDs[$id] = $v

                if ($v._['global']) {
                    $DTD._.globalIDs[$id] = $v
                }

                if ($v.count -gt 1) {
                    addReverseMapping $v
                }
            }
        }
    }

    # postpone printing these small sections until all contained info is known
    $script:printPostponed = [regex] '/(Info|Tracks|ChapterAtom|Tag|EditionEntry|CuePoint)/$'
    $script:printPretty = [regex] (
        '/Segment/$|' +
        '/Info/(TimecodeScale|SegmentUID)$|' +
        '/Tracks/TrackEntry/(|' +
            'Video/(|(Pixel|Display)(Width|Height)|FlagInterlaced)|' +
            'Audio/(|(Output)?SamplingFrequency|Channels|BitDepth)|' +
            'Track(Number|UID|Type)|Codec(ID|Private)|Language|Name|DefaultDuration|MinCache|' +
            'Flag(Lacing|Default|Forced|Enabled)|CodecDecodeAll|MaxBlockAdditionID|TrackTimecodeScale' +
        ')$|' +
        '/Chapters/EditionEntry/(' +
            'EditionUID|EditionFlag(Hidden|Default|Ordered)|' +
            'ChapterAtom/(|' +
                'Chapter(' +
                    'Display/(|Chap(String|Language|Country))|' +
                    'UID|Time(Start|End)|Flag(Hidden|Enabled)' +
                ')' +
            ')' +
        ')$|' +
        '/Attachments/AttachedFile/|' +
        '/Tags/Tag/|' +
        '/SeekHead/|' +
        '/EBML/|' +
        '/Void\b|' +
        '/CuePoint/'
    )
    $script:numberFormat = [Globalization.CultureInfo]::InvariantCulture
    $script:lookupChunkSize = 4096

    $script:dummyMeta = @{}

    add-member scriptMethod closest {
        # finds the closest parent
        param(
            [string]$name='', # name string, case-insensitive, takes precedence over 'match'
            [string]$match='' # path regexp, case-insensitive
        )
        for ($m = $this; $m['name']; $m = $m.parent._) {
            if (($name -and $m.name -eq $name) `
            -or ($match -and $m.path -match $match)) {
                return $m.ref
            }
        }
    } -inputObject $dummyMeta

    add-member scriptMethod find {
        # finds all nested children
        # returns: $null, a single object of primitive type or an array of 1 or more entries
        param(
            [string]$name='', # name string, case-insensitive, takes precedence over 'match'
            [string]$match='' # path regexp, case-insensitive
        )
        if ($this.ref -isnot [hashtable]) {
            return
        }
        $results = [ordered]@{}
        forEach ($child in $this.ref.getEnumerator()) {
            forEach ($meta in $child.value._) {
                if (($name -and $meta.name -eq $name) `
                -or ($match -and $meta.path -match $match)) {
                    $hash = '' + [Runtime.CompilerServices.RuntimeHelpers]::getHashCode($meta.ref)
                    if (!$results.contains($hash)) {
                        $results[$hash] = $meta.ref
                    }
                }
                if ($meta.type -eq 'container') {
                    forEach ($r in $meta.find($name,$match,0xDEADBEEF).getEnumerator()) {
                        $results[$r.name] = $r.value
                    }
                }
            }
        }
        if ($args -eq 0xDEADBEEF) { $results }
        elseif ($results.count -eq 0) { $null }
        elseif ($results.count -gt 1) { $results.values }
        elseif ($results.values[0]._.type -in 'binary','container') { ,$results.values[0] }
        else { $results.values[0] }
    } -inputObject $dummyMeta

    $script:dummyContainer = add-member _ $dummyMeta -inputObject (@{}) -passthru

    $script:colors = @{
        bold = 'white'
        normal = 'gray'
        dim = 'darkgray'

        container = 'white'
        string = 'green'
        stringdim = 'darkgreen'
        stringdim2 = 'darkcyan' # custom simple tag
        value = 'yellow'

        reference = 'cyan' # referenced track name in Tags
    }

    $script:DTD = @{
        _=@{
            globalIDs = @{}
            trackTypes = @{
                   1 = 'Video'
                   2 = 'Audio'
                0x10 = 'Logo'
                0x11 = 'Subtitle'
                0x12 = 'Buttons'
                0x20 = 'Control'
            }
        }

        CRC32 = @{ _=@{ id=0xbf; type='binary'; global=$true } }
        Void = @{ _=@{ id=0xec; type='binary'; global=$true; multiple=$true } }
        SignatureSlot = @{ _=@{ id=0x1b538667; type='container'; global=$true; multiple=$true }
            SignatureAlgo = @{ _=@{ id=0x7e8a; type='uint' } }
            SignatureHash = @{ _=@{ id=0x7e9a; type='uint' } }
            SignaturePublicKey = @{ _=@{ id=0x7ea5; type='binary' } }
            Signature = @{ _=@{ id=0x7eb5; type='binary' } }
            SignatureElements = @{ _=@{ id=0x7e5b; type='container' }
                SignatureElementList = @{ _=@{ id=0x7e7b; type='container'; multiple=$true }
                    SignedElement = @{ _=@{ id=0x6532; type='binary'; multiple=$true } }
                }
            }
        }

        EBML = @{ _=@{ id=0x1a45dfa3; type='container'; multiple=$true }
            EBMLVersion = @{ _=@{ id=0x4286; type='uint'; value=1 } }
            EBMLReadVersion = @{ _=@{ id=0x42f7; type='uint'; value=1 } }
            EBMLMaxIDLength = @{ _=@{ id=0x42f2; type='uint'; value=4 } }
            EBMLMaxSizeLength = @{ _=@{ id=0x42f3; type='uint'; value=8 } }
            DocType = @{ _=@{ id=0x4282; type='string' } }
            DocTypeVersion = @{ _=@{ id=0x4287; type='uint'; value=1 } }
            DocTypeReadVersion = @{ _=@{ id=0x4285; type='uint'; value=1 } }
        }

        # Matroska DTD
        Segment = @{ _=@{ id=0x18538067; type='container'; multiple=$true }

            # Meta Seek Information
            SeekHead = @{ _=@{ id=0x114d9b74; type='container'; multiple=$true }
                Seek = @{ _=@{ id=0x4dbb; type='container'; multiple=$true }
                    SeekID = @{ _=@{ id=0x53ab; type='binary' } }
                    SeekPosition = @{ _=@{ id=0x53ac; type='uint' } }
                }
            }

            # Segment Information
            Info = @{ _=@{ id=0x1549a966; type='container'; multiple=$true }
                SegmentUID = @{ _=@{ id=0x73a4; type='binary' } }
                SegmentFilename = @{ _=@{ id=0x7384; type='string' } }
                PrevUID = @{ _=@{ id=0x3cb923; type='binary' } }
                PrevFilename = @{ _=@{ id=0x3c83ab; type='string' } }
                NextUID = @{ _=@{ id=0x3eb923; type='binary' } }
                NextFilename = @{ _=@{ id=0x3e83bb; type='string' } }
                SegmentFamily = @{ _=@{ id=0x4444; type='binary'; multiple=$true } }
                ChapterTranslate = @{ _=@{ id=0x6924; type='container'; multiple=$true }
                    ChapterTranslateEditionUID = @{ _=@{ id=0x69fc; type='uint'; multiple=$true } }
                    ChapterTranslateCodec = @{ _=@{ id=0x69bf; type='uint' } }
                    ChapterTranslateID = @{ _=@{ id=0x69a5; type='binary' } }
                }
                TimecodeScale = @{ _=@{ id=0x2ad7b1; type='uint'; value=1000000 } }
                Duration = @{ _=@{ id=0x4489; type='float' } }
                DateUTC = @{ _=@{ id=0x4461; type='date' } }
                Title = @{ _=@{ id=0x7ba9; type='string' } }
                MuxingApp = @{ _=@{ id=0x4d80; type='string' } }
                WritingApp = @{ _=@{ id=0x5741; type='string' } }
            }

            # Cluster
            Cluster = @{ _=@{ id=0x1f43b675; type='container'; multiple=$true }
                Timecode = @{ _=@{ id=0xe7; type='uint' } }
                SilentTracks = @{ _=@{ id=0x5854; type='container' }
                    SilentTrackNumber = @{ _=@{ id=0x58d7; type='uint'; multiple=$true } }
                }
                Position = @{ _=@{ id=0xa7; type='uint' } }
                PrevSize = @{ _=@{ id=0xab; type='uint' } }
                SimpleBlock = @{ _=@{ id=0xa3; type='binary'; multiple=$true } }
                BlockGroup = @{ _=@{ id=0xa0; type='container'; multiple=$true }
                    Block = @{ _=@{ id=0xa1; type='binary' } }
                    BlockVirtual = @{ _=@{ id=0xa2; type='binary' } }
                    BlockAdditions = @{ _=@{ id=0x75a1; type='container' }
                        BlockMore = @{ _=@{ id=0xa6; type='container'; multiple=$true }
                            BlockAddID = @{ _=@{ id=0xee; type='uint' } }
                            BlockAdditional = @{ _=@{ id=0xa5; type='binary' } }
                        }
                    }
                    BlockDuration = @{ _=@{ id=0x9b; type='uint' } }
                    ReferencePriority = @{ _=@{ id=0xfa; type='uint' } }
                    ReferenceBlock = @{ _=@{ id=0xfb; type='int'; multiple=$true } }
                    ReferenceVirtual = @{ _=@{ id=0xfd; type='int' } }
                    CodecState = @{ _=@{ id=0xa4; type='binary' } }
                    DiscardPadding = @{ _=@{ id=0x75a2; type='int' } }
                    Slices = @{ _=@{ id=0x8e; type='container' }
                        TimeSlice = @{ _=@{ id=0xe8; type='container'; multiple=$true }
                            LaceNumber = @{ _=@{ id=0xcc; type='uint'; value=0 } }
                            FrameNumber = @{ _=@{ id=0xcd; type='uint'; value=0 } }
                            BlockAdditionID = @{ _=@{ id=0xcb; type='uint'; value=0 } }
                            Delay = @{ _=@{ id=0xce; type='uint'; value=0 } }
                            SliceDuration = @{ _=@{ id=0xcf; type='uint' } }
                        }
                    }
                    ReferenceFrame = @{ _=@{ id=0xc8; type='container' }
                        ReferenceOffset = @{ _=@{ id=0xc9; type='uint'; value=0 } }
                        ReferenceTimeCode = @{ _=@{ id=0xca; type='uint'; value=0 } }
                    }
                EncryptedBlock = @{ _=@{ id=0xaf; type='binary'; multiple=$true } }
                }
            }

            # Track
            Tracks = @{ _=@{ id=0x1654ae6b; type='container'; multiple=$true }
                TrackEntry = @{ _=@{ id=0xae; type='container'; multiple=$true }
                    TrackNumber = @{ _=@{ id=0xd7; type='uint' } }
                    TrackUID = @{ _=@{ id=0x73c5; type='uint' } }
                    TrackType = @{ _=@{ id=0x83; type='uint' } }
                    FlagEnabled = @{ _=@{ id=0xb9; type='uint'; value=1 } }
                    FlagDefault = @{ _=@{ id=0x88; type='uint'; value=1 } }
                    FlagForced = @{ _=@{ id=0x55aa; type='uint'; value=0 } }
                    FlagLacing = @{ _=@{ id=0x9c; type='uint'; value=1 } }
                    MinCache = @{ _=@{ id=0x6de7; type='uint'; value=0 } }
                    MaxCache = @{ _=@{ id=0x6df8; type='uint' } }
                    DefaultDuration = @{ _=@{ id=0x23e383; type='uint' } }
                    DefaultDecodedFieldDuration = @{ _=@{ id=0x234e7a; type='uint' } }
                    TrackTimecodeScale = @{ _=@{ id=0x23314f; type='float'; value=1.0 } }
                    TrackOffset = @{ _=@{ id=0x537f; type='int'; value=0 } }
                    MaxBlockAdditionID = @{ _=@{ id=0x55ee; type='uint'; value=0 } }
                    Name = @{ _=@{ id=0x536e; type='string' } }
                    Language = @{ _=@{ id=0x22b59c; type='string'; value='eng' } }
                    CodecID = @{ _=@{ id=0x86; type='string' } }
                    CodecPrivate = @{ _=@{ id=0x63a2; type='binary' } }
                    CodecName = @{ _=@{ id=0x258688; type='string' } }
                    AttachmentLink = @{ _=@{ id=0x7446; type='uint' } }
                    CodecSettings = @{ _=@{ id=0x3a9697; type='string' } }
                    CodecInfoURL = @{ _=@{ id=0x3b4040; type='string'; multiple=$true } }
                    CodecDownloadURL = @{ _=@{ id=0x26b240; type='string'; multiple=$true } }
                    CodecDecodeAll = @{ _=@{ id=0xaa; type='uint'; value=1 } }
                    TrackOverlay = @{ _=@{ id=0x6fab; type='uint'; multiple=$true } }
                    CodecDelay = @{ _=@{ id=0x56aa; type='uint' } }
                    SeekPreRoll = @{ _=@{ id=0x56bb; type='uint' } }
                    TrackTranslate = @{ _=@{ id=0x6624; type='container'; multiple=$true }
                        TrackTranslateEditionUID = @{ _=@{ id=0x66fc; type='uint'; multiple=$true } }
                        TrackTranslateCodec = @{ _=@{ id=0x66bf; type='uint' } }
                        TrackTranslateTrackID = @{ _=@{ id=0x66a5; type='binary' } }
                    }

                    # Video
                    Video = @{ _=@{ id=0xe0; type='container' }
                        FlagInterlaced = @{ _=@{ id=0x9a; type='uint'; value=0 } }
                        StereoMode = @{ _=@{ id=0x53b8; type='uint'; value=0 } }
                        AlphaMode = @{ _=@{ id=0x53c0; type='uint' } }
                        OldStereoMode = @{ _=@{ id=0x53b9; type='uint' } }
                        PixelWidth = @{ _=@{ id=0xb0; type='uint' } }
                        PixelHeight = @{ _=@{ id=0xba; type='uint' } }
                        PixelCropBottom = @{ _=@{ id=0x54aa; type='uint' } }
                        PixelCropTop = @{ _=@{ id=0x54bb; type='uint' } }
                        PixelCropLeft = @{ _=@{ id=0x54cc; type='uint' } }
                        PixelCropRight = @{ _=@{ id=0x54dd; type='uint' } }
                        DisplayWidth = @{ _=@{ id=0x54b0; type='uint' } }
                        DisplayHeight = @{ _=@{ id=0x54ba; type='uint' } }
                        DisplayUnit = @{ _=@{ id=0x54b2; type='uint'; value=0 } }
                        AspectRatioType = @{ _=@{ id=0x54b3; type='uint'; value=0 } }
                        ColourSpace = @{ _=@{ id=0x2eb524; type='binary' } }
                        GammaValue = @{ _=@{ id=0x2fb523; type='float' } }
                        FrameRate = @{ _=@{ id=0x2383e3; type='float' } }
                    }

                    # Audio
                    Audio = @{ _=@{ id=0xe1; type='container' }
                        SamplingFrequency = @{ _=@{ id=0xb5; type='float'; value=8000.0 } }
                        OutputSamplingFrequency = @{ _=@{ id=0x78b5; type='float'; value=8000.0 } }
                        Channels = @{ _=@{ id=0x9f; type='uint'; value=1 } }
                        ChannelPositions = @{ _=@{ id=0x7d7b; type='binary' } }
                        BitDepth = @{ _=@{ id=0x6264; type='uint' } }
                    }

                    TrackOperation = @{ _=@{ id=0xe2; type='container' }
                        TrackCombinePlanes = @{ _=@{ id=0xe3; type='container' }
                            TrackPlane = @{ _=@{ id=0xe4; type='container'; multiple=$true }
                                TrackPlaneUID = @{ _=@{ id=0xe5; type='uint' } }
                                TrackPlaneType = @{ _=@{ id=0xe6; type='uint' } }
                            }
                        }
                        TrackJoinBlocks = @{ _=@{ id=0xe9; type='container' }
                            TrackJoinUID = @{ _=@{ id=0xed; type='uint'; multiple=$true } }
                        }
                    }

                    TrickTrackUID = @{ _=@{ id=0xc0; type='uint' } }
                    TrickTrackSegmentUID = @{ _=@{ id=0xc1; type='binary' } }
                    TrickTrackFlag = @{ _=@{ id=0xc6; type='uint' } }
                    TrickMasterTrackUID = @{ _=@{ id=0xc7; type='uint' } }
                    TrickMasterTrackSegmentUID = @{ _=@{ id=0xc4; type='binary' } }

                    # Content Encoding
                    ContentEncodings = @{ _=@{ id=0x6d80; type='container' }
                        ContentEncoding = @{ _=@{ id=0x6240; type='container'; multiple=$true }
                            ContentEncodingOrder = @{ _=@{ id=0x5031; type='uint'; value=0 } }
                            ContentEncodingScope = @{ _=@{ id=0x5032; type='uint'; value=1 } }
                            ContentEncodingType = @{ _=@{ id=0x5033; type='uint' } }
                            ContentCompression = @{ _=@{ id=0x5034; type='container' }
                                ContentCompAlgo = @{ _=@{ id=0x4254; type='uint'; value=0 } }
                                ContentCompSettings = @{ _=@{ id=0x4255; type='binary' } }
                            }
                            ContentEncryption = @{ _=@{ id=0x5035; type='container' }
                                ContentEncAlgo = @{ _=@{ id=0x47e1; type='uint'; value=0 } }
                                ContentEncKeyID = @{ _=@{ id=0x47e2; type='binary' } }
                                ContentSignature = @{ _=@{ id=0x47e3; type='binary' } }
                                ContentSigKeyID = @{ _=@{ id=0x47e4; type='binary' } }
                                ContentSigAlgo = @{ _=@{ id=0x47e5; type='uint' } }
                                ContentSigHashAlgo = @{ _=@{ id=0x47e6; type='uint' } }
                            }
                        }
                    }
                }
            }

            # Cueing Data
            Cues = @{ _=@{ id=0x1c53bb6b; type='container' }
                CuePoint = @{ _=@{ id=0xbb; type='container'; multiple=$true }
                    CueTime = @{ _=@{ id=0xb3; type='uint' } }
                    CueTrackPositions = @{ _=@{ id=0xb7; type='container'; multiple=$true }
                        CueTrack = @{ _=@{ id=0xf7; type='uint' } }
                        CueClusterPosition = @{ _=@{ id=0xf1; type='uint' } }
                        CueRelativePosition = @{ _=@{ id=0xf0; type='uint' } }
                        CueDuration = @{ _=@{ id=0xb2; type='uint' } }
                        CueBlockNumber = @{ _=@{ id=0x5378; type='uint'; value=1 } }
                        CueCodecState = @{ _=@{ id=0xea; type='uint'; value=0 } }
                        CueReference = @{ _=@{ id=0xdb; type='container'; multiple=$true }
                            CueRefTime = @{ _=@{ id=0x96; type='uint' } }
                            CueRefCluster = @{ _=@{ id=0x97; type='uint' } }
                            CueRefNumber = @{ _=@{ id=0x535f; type='uint'; value=1 } }
                            CueRefCodecState = @{ _=@{ id=0xeb; type='uint'; value=0 } }
                        }
                    }
                }
            }

            # Attachment
            Attachments = @{ _=@{ id=0x1941a469; type='container' }
                AttachedFile = @{ _=@{ id=0x61a7; type='container'; multiple=$true }
                    FileDescription = @{ _=@{ id=0x467e; type='string' } }
                    FileName = @{ _=@{ id=0x466e; type='string' } }
                    FileMimeType = @{ _=@{ id=0x4660; type='string' } }
                    FileData = @{ _=@{ id=0x465c; type='binary' } }
                    FileUID = @{ _=@{ id=0x46ae; type='uint' } }
                    FileReferral = @{ _=@{ id=0x4675; type='binary' } }
                    FileUsedStartTime = @{ _=@{ id=0x4661; type='uint' } }
                    FileUsedEndTime = @{ _=@{ id=0x4662; type='uint' } }
                }
            }

            # Chapters
            Chapters = @{ _=@{ id=0x1043a770; type='container' }
                EditionEntry = @{ _=@{ id=0x45b9; type='container'; multiple=$true }
                    EditionUID = @{ _=@{ id=0x45bc; type='uint' } }
                    EditionFlagHidden = @{ _=@{ id=0x45bd; type='uint' } }
                    EditionFlagDefault = @{ _=@{ id=0x45db; type='uint' } }
                    EditionFlagOrdered = @{ _=@{ id=0x45dd; type='uint' } }
                    ChapterAtom = @{ _=@{ id=0xb6; type='container'; multiple=$true; recursiveNesting=$true }
                        ChapterUID = @{ _=@{ id=0x73c4; type='uint' } }
                        ChapterStringUID = @{ _=@{ id=0x5654; type='binary' } }
                        ChapterTimeStart = @{ _=@{ id=0x91; type='uint' } }
                        ChapterTimeEnd = @{ _=@{ id=0x92; type='uint' } }
                        ChapterFlagHidden = @{ _=@{ id=0x98; type='uint'; value=0 } }
                        ChapterFlagEnabled = @{ _=@{ id=0x4598; type='uint'; value=0 } }
                        ChapterSegmentUID = @{ _=@{ id=0x6e67; type='binary' } }
                        ChapterSegmentEditionUID = @{ _=@{ id=0x6ebc; type='uint' } }
                        ChapterPhysicalEquiv = @{ _=@{ id=0x63c3; type='uint' } }
                        ChapterTrack = @{ _=@{ id=0x8f; type='container' }
                            ChapterTrackNumber = @{ _=@{ id=0x89; multiple=$true; type='uint' } }
                        }
                        ChapterDisplay = @{ _=@{ id=0x80; type='container'; multiple=$true }
                            ChapString = @{ _=@{ id=0x85; type='string' } }
                            ChapLanguage = @{ _=@{ id=0x437c; type='string'; multiple=$true; value='eng' } }
                            ChapCountry = @{ _=@{ id=0x437e; type='string'; multiple=$true } }
                        }
                        ChapProcess = @{ _=@{ id=0x6944; type='container'; multiple=$true }
                            ChapProcessCodecID = @{ _=@{ id=0x6955; type='uint' } }
                            ChapProcessPrivate = @{ _=@{ id=0x450d; type='binary' } }
                            ChapProcessCommand = @{ _=@{ id=0x6911; type='container'; multiple=$true }
                                ChapProcessTime = @{ _=@{ id=0x6922; type='uint' } }
                                ChapProcessData = @{ _=@{ id=0x6933; type='binary' } }
                            }
                        }
                    }
                }
            }

            # Tagging
            Tags = @{ _=@{ id=0x1254c367; type='container'; multiple=$true }
                Tag = @{ _=@{ id=0x7373; type='container'; multiple=$true }
                    Targets = @{ _=@{ id=0x63c0; type='container' }
                        TargetTypeValue = @{ _=@{ id=0x68ca; type='uint' } }
                        TargetType = @{ _=@{ id=0x63ca; type='string' } }
                        TagTrackUID = @{ _=@{ id=0x63c5; type='uint'; multiple=$true; value=0 } }
                        TagEditionUID = @{ _=@{ id=0x63c9; type='uint'; multiple=$true } }
                        TagChapterUID = @{ _=@{ id=0x63c4; type='uint'; multiple=$true; value=0 } }
                        TagAttachmentUID = @{ _=@{ id=0x63c6; type='uint'; multiple=$true; value=0 } }
                    }
                    SimpleTag = @{ _=@{ id=0x67c8; type='container'; multiple=$true; recursiveNesting=$true }
                        TagName = @{ _=@{ id=0x45a3; type='string' } }
                        TagLanguage = @{ _=@{ id=0x447a; type='string' } }
                        TagDefault = @{ _=@{ id=0x4484; type='uint' } }
                        TagString = @{ _=@{ id=0x4487; type='string' } }
                        TagBinary = @{ _=@{ id=0x4485; type='binary' } }
                    }
                }
            }
        }
    }

    addReverseMapping $DTD
}
#endregion

export-moduleMember -function parseMKV
