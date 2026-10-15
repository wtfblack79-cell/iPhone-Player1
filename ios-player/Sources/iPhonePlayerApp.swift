import SwiftUI
@main
struct iPhonePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 60))
            Text("iPhone Player")
                .font(.largeTitle)
                .bold()
            Text("Твой личный аудиоплеер")
                .font(.title3)
        }
        .padding()
    }
}
