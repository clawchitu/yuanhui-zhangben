// 用 macOS 的 Vision 从一张截图里认出所有 EAN-13 条码，一行一个打印出来（审核用条码页的离线核对用，见 review-barcodes-scan.sh）。
// 用法：swift deploy/test/decode-barcodes.swift <图片.png>
import Foundation
import Vision
import AppKit

let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("读不了图片 \(path)\n".data(using: .utf8)!); exit(1)
}
let req = VNDetectBarcodesRequest()
req.symbologies = [.ean13]
try VNImageRequestHandler(cgImage: cg).perform([req])
for r in (req.results ?? []) { if let s = r.payloadStringValue { print(s) } }
