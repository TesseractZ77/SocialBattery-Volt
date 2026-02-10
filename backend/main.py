import sqlite3
import math
import json
import asyncio
from datetime import datetime
from typing import Optional, List
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
import uvicorn

# --- Configuration ---
# --- Configuration ---
DB_FILE = "volt.db"
HOME_COORDS = (37.7749, -122.4194) # Default SF

# --- Logic Class (Adapted from User Request) ---
class VoltCore:
    def __init__(self, home_lat: float, home_lon: float, baseline_hrv: float = 50.0):
        self.home_coords = (home_lat, home_lon)
        self.baseline_hrv = baseline_hrv
        
        # Load state from DB
        self.level = self._load_state()
        
        # Config
        self.config = {
            "home_radius_km": 0.1,      # 100m
            "charge_rate_min": 1.0,     # Charge 1.0% / min
            "base_drain_min": 0.1,      # Base drain 0.1% / min
            "social_factor": 0.25,      # Drain per device
            "max_stress_mult": 3.0      # Max stress multiplier
        }

    def _load_state(self) -> float:
        conn = sqlite3.connect(DB_FILE)
        c = conn.cursor()
        c.execute('''CREATE TABLE IF NOT EXISTS battery_state
                     (id INTEGER PRIMARY KEY, level REAL, last_updated TEXT)''')
        c.execute("SELECT level FROM battery_state WHERE id=1")
        row = c.fetchone()
        if row:
            level = row[0]
        else:
            level = 100.0
            c.execute("INSERT INTO battery_state (id, level, last_updated) VALUES (1, ?, ?)", 
                      (level, datetime.now().isoformat()))
            conn.commit()
        conn.close()
        return level

    def _save_state(self):
        conn = sqlite3.connect(DB_FILE)
        c = conn.cursor()
        c.execute("UPDATE battery_state SET level = ?, last_updated = ? WHERE id=1", 
                  (self.level, datetime.now().isoformat()))
        conn.commit()
        conn.close()

    def _get_distance_km(self, lat: float, lon: float) -> float:
        """Haversine formula"""
        R = 6371.0
        phi1, phi2 = math.radians(self.home_coords[0]), math.radians(lat)
        dphi = math.radians(lat - self.home_coords[0])
        dlambda = math.radians(lon - self.home_coords[1])
        a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlambda/2)**2
        return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

    def update(self, lat: float, lon: float, device_count: int, hrv: Optional[float] = None, time_delta_sec: float = 60.0):
        # 1. Location Check
        distance = self._get_distance_km(lat, lon)
        is_home = distance <= self.config["home_radius_km"]
        
        multiplier = 0.0
        status = "IDLE"
        
        if is_home:
            # Charging
            rate_per_min = self.config["charge_rate_min"]
            delta = rate_per_min * (time_delta_sec / 60.0)
            status = "RECHARGING"
        else:
            # Draining
            
            # 2. HRV / Stress Multiplier
            if hrv and hrv > 0:
                multiplier = self.baseline_hrv / hrv
                multiplier = max(0.5, min(multiplier, self.config["max_stress_mult"]))
            else:
                multiplier = 1.0 
            
            # 3. Total Drain Calculation
            base_drain = self.config["base_drain_min"]
            social_drain = device_count * self.config["social_factor"]
            
            total_drain_per_min = (base_drain + social_drain) * multiplier
            delta = -(total_drain_per_min * (time_delta_sec / 60.0))
            status = "DRAINING"

        # Update Level
        self.level = max(0.0, min(100.0, self.level + delta))
        self._save_state()
        
        return {
            "current_level": round(self.level, 2),
            "status": status,
            "stress_multiplier": round(multiplier, 2),
            "is_home": is_home,
            "timestamp": datetime.now().isoformat(),
            "message": f"{status} | Stress: {multiplier:.1f}x | Devices: {device_count}"
        }

# --- WebSocket Manager ---
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)

    async def send_personal_message(self, message: dict, websocket: WebSocket):
        await websocket.send_json(message)

# --- App Setup ---
app = FastAPI(title="Volt Backend")
manager = ConnectionManager()

# Initialize Core
# In a real app, users would have proper sessions. 
# Here we use a singleton for the demo user.
battery_core = VoltCore(HOME_COORDS[0], HOME_COORDS[1])

@app.get("/")
def health_check():
    return {"status": "ok"}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    last_time = datetime.now()
    try:
        while True:
            # Wait for data from client
            data = await websocket.receive_json()
            
            # Parse Data
            lat = data.get("latitude", 0.0)
            lon = data.get("longitude", 0.0)
            device_count = data.get("nearby_device_count", 0)
            hrv = data.get("hrv_value")
            
            # Calculate Time Delta for smoother updates
            now = datetime.now()
            delta_sec = (now - last_time).total_seconds()
            if delta_sec <= 0: delta_sec = 1.0 # prevent div by zero
            last_time = now
            
            # Process Update
            result = battery_core.update(
                lat=lat, 
                lon=lon, 
                device_count=device_count, 
                hrv=hrv, 
                time_delta_sec=delta_sec
            )
            
            # Push Update back
            await manager.send_personal_message(result, websocket)
            
    except WebSocketDisconnect:
        manager.disconnect(websocket)
        print("Client disconnected")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
