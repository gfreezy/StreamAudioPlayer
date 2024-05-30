# SteamAudioPlayer
Playing while streaming mp3/other audio file from internet.

Source:
1. Remote URL
2. Remote websocket
3. Remote socket or any protocol

# Install
```
.package(url: "https://github.com/gfreezy/StreamAudioPlayer", branch: "main")
```

# Usage
## Stream from URL
```swift
import StreamAudio
let downloader = URLAudioPlayer(URL(string: "https://freetestdata.com/wp-content/uploads/2021/09/Free_Test_Data_100KB_MP3.mp3")!)
try await downloader.play()

# Do any other things.

try await downloader.waitForStop()
```

## Stream from websocket
```swift
import StreamAudio
let cachePath = "path/to/cache/the/file.mp3"
let player = StreamAudioPlayer(cachePath: cachePath, fileType: kAudioFileMP3Type)

// get mp3 data from some where
let audioData = Data(....)
// data can be written asyncly.
try player.writeData(audioData)

// start to play. You can play at any time. Player will pause when there is
// no enough data, and continue when enough data is available.
try await player.play()

// stop the player
try player.stop()

// player will stop when all data is finished or user called `stop()` func.
try await play.waitForStop()
```
