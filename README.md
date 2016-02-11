# parsemkv
Powershell module that parses a matroska .mkv file into a hierarchical object tree, optionally pretty-printing to console

Usage examples:

* **Print the entire structure**
  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print
  ```
![screenshot](https://i.imgur.com/RgqnbQM.png)

  Some entries are skipped by default, see parameter descriptions in the code.

* **Print video/audio info**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv'`
  $mkv.Tracks.Video | %{
  	'Video: {0}x{1}, {2}' -f $_.Video.PixelWidth, $_.Video.PixelHeight, $_.CodecID
  }
  $isMultiAudio = $mkv.Tracks.Audio.Capacity -gt 1
  $mkv.Tracks.Audio | %{ $index=0 } {
  	'Audio{0}: {1}{2}' -f (++$index), $_.CodecID, $_.Audio.SamplingFrequency
  }
  ```

* **Get the duration value**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv' -stopOn 'tracks' -binarySizeLimit 0
  $duration = $mkv.Info.Duration
  ```
  Parsing is stopped on 'tracks' entry and binary entries are skipped to speedup parsing

* **Extract the attachments**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv' -keepStreamOpen -binarySizeLimit 0
  forEach ($att in $mkv.find('AttachedFile')) {
  	$file = [IO.File]::create($att.FileName)
  	$mkv.reader.baseStream.position = $att.FileData._.datapos
  	$data = $mkv.reader.readBytes($att.FileData._.size)
  	$file.write($data, 0, $data.length)
  	$file.close()
  }
  $mkv.reader.close()
  ```

* **Print with filtering**
  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print -printFilter { $args[0]._.type -eq 'string' }
  ```

  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print -printFilter { $args[0] -is [datetime] }
  ```

  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print -printFilter { param($e)
  	$e._.name -match '^Chap(String|Lang|terTime)' -and `
  	$e._.closest('ChapterAtom').ChapterTimeStart.hours -ge 1
  }
  ```

* **Finding sub-elements**
  ```powershell
  $mkv = parseMKV 'c:\some\path\file.mkv'
  ```

  ```powershell
  $DisplayWidth = $mkv.find('DisplayWidth')
  $DisplayHeight = $mkv.find('DisplayHeight')
  $VideoCodecID = $DisplayWidth._.closest('TrackEntry').CodecID
  ```

  ```powershell
  $DisplayWxH = $mkv.Tracks.Video._.find('', '^Display[WH]') -join 'x'
  ```

  ```powershell
  ($mkv.find('ChapterTimeStart') | %{ $_._.displayString }) -join ", "
  ```

  ```powershell
  forEach ($chapter in $mkv.find('ChapterAtom')) {
  	'{0:h\:mm\:ss}' -f $chapter._.find('ChapterTimeStart') +
  	' - ' + $chapter._.find('ChapString')
  }
  ```
