# Volt - Social Battery Tracker v1.0

Volt provides a dynamic visual representation of your "social battery." It mimics a real battery that drains when you are socializing or in stressful environments and automatically recharges when you return home.

## Project Overview

Volt is a hybrid iOS and Python application designed to quantify social exhaustion. By combining real-time environmental data (crowd density via Bluetooth), physiological data (Heart Rate Variability via HealthKit), and geofencing (Home/Away status), Volt calculates a personalized "drain rate" for your social energy.

### Key Features
- **Dynamic Visuals**: A fluid wave animation that changes color (Green -> Yellow -> Red) based on your energy level.
- **Smart Geofencing**: Automatically detects when you leave home (starts draining) and when you return (starts recharging).
- **Crowd Sensing**: Uses Bluetooth to detect nearby devices as a proxy for crowd density.
- **Health Integration**: Apple HealthKit integration to use HRV (Heart Rate Variability) as a stress modifier.

## Tech Stack

### Frontend (iOS)
- **Language**: Swift 5
- **Framework**: SwiftUI
- **Core Frameworks**:
  - `CoreLocation`: Geofencing and location tracking.
  - `CoreBluetooth`: Scanning visible peripherals to estimate crowd size.
  - `HealthKit`: Reading HRV data.
  - `Combine`: Reactive state management.
  - `MapKit`: Address autocomplete for settings.

### Backend (Python)
- **Language**: Python 3.9+
- **Framework**: FastAPI
- **Server**: Uvicorn (ASGI)
- **Protocol**: WebSockets (Real-time bi-directional communication)
- **Data Model**: Pydantic models for state validation.

## Core Algorithm

Volt uses a custom algorithm to calculate energy status.

### 1. The Drain Formula (Away Mode)
When the user is **Away** (distance > 100m from Home), the battery drains every 5 seconds based on:

```python
Drain = (BaseRate + (CrowdFactor * 0.2)) * StressMultiplier
```

- **BaseRate**: A constant drain (e.g., 1.0 unit).
- **CrowdFactor**: Number of unique Bluetooth devices detected nearby.
  - *Example*: 10 devices adds 2.0 to the drain rate.
- **StressMultiplier**: Derived from HRV (Heart Rate Variability).
  - *Formula*: `BaselineHRV / CurrentHRV`
  - If you are stressed (low HRV), the multiplier increases (>1.0), draining battery faster.
  - If you are relaxed (high HRV), the multiplier decreases (<1.0).

### 2. The Recharge Formula (Home Mode)
When the user is **Home** (distance < 100m), the battery recharges:

```python
Recharge = BaseRechargeRate (e.g., 2.0 units per tick)
```

- Recharging stops automatically at 100%.

### Algorithm Deep Dive

#### 1. Why HRV (Heart Rate Variability)?
HRV is the gold standard for assessing the state of the autonomic nervous system.
- **The Science**: When you experience social anxiety or stress, your sympathetic nervous system becomes active, causing your heart rate to become abnormally regular (low HRV).
- **The Human Element**: The algorithm detects this drop. If your HRV is low (stress high), it applies a multiplier to the drain rate. This simulates the "human factor": in the exact same party, an introvert (who might be more stressed) will drain their battery faster than an extrovert.

#### 2. Bluetooth as a "Proxy Sensor"
Since we cannot count people directly, Bluetooth device density acts as a highly effective **proxy**.
- **The Metaphor**: This represents not just "people," but "electronic interference" and crowd complexity.
- **The Cost**: Every detected device is treated as a micro-stressor. Even without direct interaction, the mere presence of these devices contributes to the "sensing cost" of your social battery.

#### 3. Graceful Degradation
The system is designed to work robustly whether you have an Apple Watch or not.
- **With Watch**: The algorithm runs in **Dual Mode** (Physiological + Environmental). This is the most accurate reflection of your true fatigue.
- **Without Watch**: The system seamlessly degrades to **Environmental Mode**. The `stress_multiplier` defaults to `1.0`. The app remains a precise "Social Environment Sensor," calculating drain based purely on crowd density and location.

## Setup & Running

### 1. Backend
Navigate to the `backend` folder and run the server:
```bash
uvicorn main:app --reload --host 0.0.0.0
```

### 2. Frontend (iOS)
1. Open `ios/Volt/Volt.xcodeproj` in Xcode.
2. Connect your iPhone via USB.
3. Select your device as the run destination.
4. Ensure your iPhone and Mac are on the same Wi-Fi network.
5. Press **Run** (Cmd+R).

## License
MIT License - Volt Project 2026
