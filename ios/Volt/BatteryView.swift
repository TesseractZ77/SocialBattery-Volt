import SwiftUI
import CoreLocation
import Combine

// MARK: - Models
struct BatteryState: Codable {
    let current_level: Double
    let status: String
    let stress_multiplier: Double
    let is_home: Bool
    let message: String
}

// MARK: - View Model
class BatteryViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var batteryLevel: Double = 100.0
    @Published var status: String = "CONNECTING..."
    @Published var message: String = "Waiting for server..."
    @Published var isHome: Bool = true
    @Published var stressColor: Color = .green
    
    private let locationManager = CLLocationManager()
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    
    private var timer: Timer?
    
    // Config
    private var homeLocation = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    private var nearbyDevices: Int = 0
    private var hrvValue: Double = 60.0 // Mock HRV
    
    override init() {
        super.init()
        setupLocation()
        connectWebSocket()
        startDataPusher()
    }
    
    func setupLocation() {
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    func setHomeLocation() {
        // In a real app, send this to server to update config
        if let loc = locationManager.location?.coordinate {
            homeLocation = loc
            message = "Home updated locally!"
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Location updates handled in pusher
    }
    
    // MARK: - WebSocket
    func connectWebSocket() {
        // NOTE: Replace with actual IP if on device
        guard let url = URL(string: "ws://127.0.0.1:8000/ws") else { return }
        
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()
        listenForMessages()
    }
    
    func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("WS Error: \(error)")
                self?.reconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default: break
                }
                // Continue listening
                self?.listenForMessages()
            }
        }
    }
    
    func handleMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(BatteryState.self, from: data) {
            DispatchQueue.main.async {
                self.batteryLevel = decoded.current_level
                self.status = decoded.status
                self.message = decoded.message
                self.isHome = decoded.is_home
                
                // Color Logic based on Stress/Status
                if self.isHome {
                    self.stressColor = .green
                } else {
                    // Interpolate Red intensity based on stress
                    if decoded.stress_multiplier > 2.0 {
                        self.stressColor = .red
                    } else if decoded.stress_multiplier > 1.2 {
                        self.stressColor = .orange
                    } else {
                        self.stressColor = .yellow
                    }
                }
            }
        }
    }
    
    func reconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.connectWebSocket()
        }
    }
    
    func startDataPusher() {
        // Push sensor data every 2 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sendUpdate()
        }
    }
    
    func sendUpdate() {
        guard let loc = locationManager.location?.coordinate else { return }
        
        // Mocking fluctuations
        self.nearbyDevices = Int.random(in: 0...5)
        self.hrvValue = Double.random(in: 40...80)
        
        let payload: [String: Any] = [
            "latitude": loc.latitude,
            "longitude": loc.longitude,
            "nearby_device_count": self.nearbyDevices,
            "hrv_value": self.hrvValue
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: data, encoding: .utf8) {
            webSocketTask?.send(.string(jsonString)) { error in
                if let error = error {
                    print("Send error: \(error)")
                }
            }
        }
    }
}

// MARK: - Wave Shape
struct Wave: Shape {
    var offset: Angle
    var percent: Double
    
    var animatableData: Double {
        get { offset.degrees }
        set { offset = Angle(degrees: newValue) }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lowf = 0.05
        let phas = offset.radians
        
        let waveHeight = 0.05 * rect.height
        let yOffset = rect.height * (1 - percent)
        
        path.move(to: CGPoint(x: 0, y: yOffset))
        
        for x in stride(from: 0, to: rect.width, by: 1) {
            let relativeX = x / rect.width
            let sine = sin(relativeX * 10 + phas)
            let y = yOffset + waveHeight * sine
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - Main View
struct BatteryView: View {
    @StateObject private var viewModel = BatteryViewModel()
    @State private var waveOffset = Angle(degrees: 0)
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack {
                Text("VOLT")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 50)
                
                Spacer()
                
                // Battery Container
                ZStack(alignment: .bottom) {
                    // Glass Container
                    RoundedRectangle(cornerRadius: 30)
                        .stroke(Color.white.opacity(0.2), lineWidth: 2)
                        .frame(width: 200, height: 400)
                        .background(Color.white.opacity(0.05))
                    
                    // Liquid
                    Wave(offset: waveOffset, percent: viewModel.batteryLevel / 100.0)
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [viewModel.stressColor.opacity(0.7), viewModel.stressColor]),
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .frame(width: 196, height: 396)
                        .mask(RoundedRectangle(cornerRadius: 28))
                        .offset(y: -2)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        self.waveOffset = Angle(degrees: 360)
                    }
                }
                
                Spacer()
                
                // Status Info
                VStack(spacing: 8) {
                    Text("\(Int(viewModel.batteryLevel))%")
                        .font(.system(size: 60, weight: .thin))
                        .foregroundColor(.white)
                    
                    Text(viewModel.status)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(viewModel.stressColor)
                    
                    Text(viewModel.message)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.bottom, 30)
                
                // Set Home Button
                Button(action: {
                    viewModel.setHomeLocation()
                }) {
                    HStack {
                        Image(systemName: "house.fill")
                        Text("Set Current as Home")
                    }
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.bottom, 30)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        BatteryView()
    }
}
