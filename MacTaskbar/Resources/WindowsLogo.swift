import SwiftUI

// Windows 11 style — four panes sharing one light-to-deep blue gradient
struct WindowsLogo: View {
    var size: CGFloat = 18

    var body: some View {
        let gap: CGFloat = size * 0.10
        let sq: CGFloat = (size - gap) / 2
        let blue = Color(red: 0.0, green: 0.47, blue: 0.84) // Win11 blue

        LinearGradient(
            colors: [Color(red: 0.36, green: 0.80, blue: 1.0), blue],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .mask(
            ZStack {
                Rectangle()
                    .frame(width: sq, height: sq)
                    .offset(x: -(sq / 2 + gap / 2), y: -(sq / 2 + gap / 2))

                Rectangle()
                    .frame(width: sq, height: sq)
                    .offset(x: sq / 2 + gap / 2, y: -(sq / 2 + gap / 2))

                Rectangle()
                    .frame(width: sq, height: sq)
                    .offset(x: -(sq / 2 + gap / 2), y: sq / 2 + gap / 2)

                Rectangle()
                    .frame(width: sq, height: sq)
                    .offset(x: sq / 2 + gap / 2, y: sq / 2 + gap / 2)
            }
        )
        .frame(width: size, height: size)
    }
}
