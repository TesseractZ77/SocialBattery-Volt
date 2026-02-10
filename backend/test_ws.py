import asyncio
import websockets
import json

async def test_ws():
    # Attempting to connect to the right port.
    # The running server is on 8002 (from tool call).
    uri = "ws://127.0.0.1:8002/ws"
    print(f"Connecting to {uri}...")
    try:
        async with websockets.connect(uri) as websocket:
            print("Connected!")
            # Mock Payload
            payload = {
                "latitude": 37.7749,
                "longitude": -122.4194, # Home
                "nearby_device_count": 0,
                "hrv_value": 70.0
            }
            
            print(f"Sending: {payload}")
            await websocket.send(json.dumps(payload))
            
            response = await websocket.recv()
            print(f"Received: {response}")
            
            # Test Away
            payload = {
                "latitude": 0.0,
                "longitude": 0.0,
                "nearby_device_count": 5,
                "hrv_value": 70.0
            }
            print(f"Sending Away: {payload}")
            await websocket.send(json.dumps(payload))
            
            response = await websocket.recv()
            print(f"Received: {response}")
    except Exception as e:
        print(f"Connection failed: {e}")

if __name__ == "__main__":
    asyncio.run(test_ws())
