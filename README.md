# parsemkv
Powershell module that parses a matroska .mkv file into a hierarchical object tree, optionally pretty-printing to console

Usage examples:

* **Print the entire structure**
  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print
  ```
![screenshot](https://i.imgur.com/sxtVJDK.png)

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
  $mkv.Attachments.AttachedFile | %{
  	$file = [IO.File]::create($_.FileName)
  	$size = $_.FileData._.size
  	$mkv._.reader.baseStream.position = $_.FileData._.datapos
  	$data = $mkv._.reader.readBytes($size)
  	$file.write($data, 0, $size)
  	$file.close()
  }
  $mkv._.reader.close()
  ```
* **Print with filtering**
  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print -printFilter { $args[0]._.type -eq 'string' }
  ```

  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print -printFilter { $args[0] -is [datetime] }
  ```

  ```powershell
  parseMKV 'c:\some\path\file.mkv' -print -printFilter {
  	param($e)
  	if ($e._.name -match '^Chap(String|Lang|terTime)') {
  		for ($atom = $e; $atom -ne $null; $atom = $atom._.parent) {
  			if ($atom._.name -eq 'ChapterAtom') {
  				if ($atom.ChapterTimeStart.hours -ge 1) {
  					$true
  				}
  			}
  		}
  	}
  }
  ```
