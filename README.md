# parsemkv
Powershell module that parses a matroska .mkv file into a hierarchical object tree, optionally pretty-printing to console

Usage examples:

* **Print the entire structure**
  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print
  ```
![screenshot](https://i.imgur.com/RgqnbQM.png)

  Some entries are skipped by default, see parameter descriptions in the code.

  Unabridged output: `parseMKV '....' -printRaw`

* **Get the duration value**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv' -get Info -binarySizeLimit 0
  $duration = $mkv.Segment.Info.Duration
  ```
  Parsing is stopped after 'Info' section is read and binary entries are skipped for speedup

* **Print video/audio info**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv'`
  $mkv.Segment.Tracks.Video | %{
  	'Video: {0}x{1}, {2}' -f $_.Video.PixelWidth, $_.Video.PixelHeight, $_.CodecID
  }
  $isMultiAudio = $mkv.Segment.Tracks.Audio.Capacity -gt 1
  $mkv.Segment.Tracks.Audio | %{ $index=0 } {
  	'Audio{0}: {1}{2}' -f (++$index), $_.CodecID, $_.Audio.SamplingFrequency
  }
  ```

* **Extract all attachments**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv' -keepStreamOpen -binarySizeLimit 0
  $outputDir = 'd:\'
  echo "Extracting to $outputDir"
  forEach ($att in $mkv.find('AttachedFile')) {
  	write-host "`t$($att.FileName)"
  	$file = [IO.File]::create((join-path $outputDir $att.FileName))
  	$mkv.reader.baseStream.position = $att.FileData._.datapos
  	$data = $mkv.reader.readBytes($att.FileData._.size)
  	$file.write($data, 0, $data.length)
  	$file.close()
  }
  $mkv.reader.close()
  ```

* **Find/access elements**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv'
  ```

  ```powershell
  $DisplayWidth = $mkv.find('DisplayWidth')
  $DisplayHeight = $mkv.find('DisplayHeight')
  $VideoCodecID = $DisplayWidth._.closest('TrackEntry').CodecID
  ```

  ```powershell
  $DisplayWxH = $mkv.Segment.Tracks.Video._.find('', '^Display[WH]') -join 'x'
  ```

  ```powershell
  $mkv.find('ChapterTimeStart')._.displayString -join ", "
  ```

  ```powershell
  forEach ($chapter in $mkv.find('ChapterAtom')) {
  	'{0:h\:mm\:ss}' -f $chapter._.find('ChapterTimeStart') +
  	' - ' + $chapter._.find('ChapString')
  }
  ```
