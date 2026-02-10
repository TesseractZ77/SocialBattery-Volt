# Volt - Run Instructions

## 1. Backend Server (Python)

The backend engine handles the logic and battery state for Volt.

### Prerequisite
Ensure Python 3.10+ is installed.

### Setup
1. Open a terminal and navigate to the project root.
2. Go to the backend folder:
   ```bash
   cd backend
   ```
3. Install dependencies:
   ```bash
   pip install fastapi uvicorn[standard]
   ```

### Start Server
1. Run the server:
   ```bash
   python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
   ```
   *Note: Using `0.0.0.0` makes the server accessible to other devices on your local network (like your iPhone).*

2. Verify it's running by opening a browser to: `http://localhost:8000/` (You should see `{"status": "ok"}`).

---

## 2. Frontend App (iOS Simulator / Device)

### Setup
1. Open **Xcode**.
2. Create a new **iOS App** project named `SocialBattery` (choose SwiftUI).
3. Replace `SocialBatteryApp.swift` and `BatteryView.swift` with the files provided in `ios/SocialBattery/`.
4. Add permission strings to `Info.plist`:
   * Key: `Privacy - Location When In Use Usage Description`
   * Value: "We need your location to know if you are home."

### Connecting to Local Server
**Important**: The iOS Simulator cannot reach `localhost` effectively if running inside a sandbox, but usually `127.0.0.1` works fine on Simulator.

For a **Physical Device**:
1. Find your computer's local IP address (e.g., `192.168.1.50`).
2. Update `BatteryView.swift` line ~43:
   ```swift
   guard let url = URL(string: "ws://192.168.1.50:8000/ws") else { return }
   ```
3. Build and run on your device.

---

## Expected Behavior
1. The app will connect via WebSocket (status: "CONNECTING..." -> "IDLE" or "RECHARGING").
2. While moving around (or simulating location in Xcode -> Debug -> Simulate Location), the battery state will update in real-time.
