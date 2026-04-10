# SyncSensorApp

SyncSensorApp is a high-precision, multi-modal iOS data logging application. It is designed for researchers, developers, and data scientists who need to record rigorously synchronized Camera, Microphone, and IMU (Inertial Measurement Unit) data for offline analysis, machine learning, or gait analysis.

## 🚀 Key Features

- **Strict Time Synchronization**: Uses the iOS system uptime (`mach_absolute_time`) as a unified clock source to ensure all sensors and media frames share the same absolute timeline.
- **High-Frequency IMU Logging**: Captures Accelerometer, Gravity, Gyroscope, and Orientation (Roll, Pitch, Yaw) at customizable rates up to 100Hz.
- **Media Recording**: Records H.264 Video and AAC Audio into a single `.mp4` container, with configurable frame rates (up to 60 FPS).
- **Real-Time Visualization**: Features a live dashboard displaying real-time audio levels and XYZ waveforms for IMU sensors.
- **Robust Data Management**: 
  - Browse recorded sessions directly within the app.
  - Preview `CSV` files in a structured data grid.
  - Playback recorded `.mp4` videos.
  - **Extract Audio**: One-click extraction of raw `.wav` audio from video files.
- **Easy Exporting**: Compresses session folders into `.zip` archives with a single tap and shares them via AirDrop, Mail, or Files using the native iOS Share Sheet.

## 📁 Output Data Structure

Each recording session generates a folder (e.g., `Record_YYYYMMDD_HHmmss`) containing the following files:

- `Metadata.csv`: Contains device information, sample rates, and the absolute recording start time (`T0`). Essential for offline data alignment.
- `Video.mp4`: The recorded video with synchronized audio.
- `Accelerometer.csv`: Raw 3-axis acceleration data.
- `Gravity.csv`: 3-axis gravity vector data.
- `Gyroscope.csv`: 3-axis rotation rate data.
- `Orientation.csv`: Device attitude represented as Roll, Pitch, and Yaw.

### CSV Format
IMU `.csv` files are tab-separated (`\t`) and follow this format:
```
time    seconds_elapsed    z    y    x
```
*(Note: The `time` column uses the absolute system uptime in seconds.)*



## ⚙️ Requirements

- **OS**: iOS 15.0 or later
- **IDE**: Xcode 14.0 or later
- **Language**: Swift 5.7+

## 📦 Dependencies

This project uses the Swift Package Manager (SPM).

- ZIPFoundation: Used for creating `.zip` archives of the recorded data blocks.

## 📝 License

This project is provided as-is for data collection and research purposes.