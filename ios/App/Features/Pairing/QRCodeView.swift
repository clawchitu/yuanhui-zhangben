import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 二维码（CoreImage，纠错级 M）。按整数倍放大、不插值，边缘清楚，老手机的相机也好认
struct QRCodeView: View {
    let payload: String
    var dimmed = false

    var body: some View {
        if let img = Self.image(payload) {
            Image(decorative: img, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .opacity(dimmed ? 0.12 : 1)
        } else {
            Rectangle().fill(Tokens.Palette.mute)
        }
    }

    static func image(_ payload: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(payload.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
