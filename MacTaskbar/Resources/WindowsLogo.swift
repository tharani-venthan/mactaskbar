import SwiftUI

// Windows 11 style — solid blue, single pane logo
struct WindowsLogo: View {
    var size: CGFloat = 18

    var body: some View {
        let gap: CGFloat = size * 0.10
        let sq: CGFloat = (size - gap) / 2
        let blue = Color(red: 0.0, green: 0.47, blue: 0.84) // Win11 blue

        ZStack {
            Rectangle()
                .fill(blue)
                .frame(width: sq, height: sq)
                .offset(x: -(sq / 2 + gap / 2), y: -(sq / 2 + gap / 2))

            Rectangle()
                .fill(blue)
                .frame(width: sq, height: sq)
                .offset(x: sq / 2 + gap / 2, y: -(sq / 2 + gap / 2))

            Rectangle()
                .fill(blue)
                .frame(width: sq, height: sq)
                .offset(x: -(sq / 2 + gap / 2), y: sq / 2 + gap / 2)

            Rectangle()
                .fill(blue)
                .frame(width: sq, height: sq)
                .offset(x: sq / 2 + gap / 2, y: sq / 2 + gap / 2)
        }
        .frame(width: size, height: size)
    }
}
