// 生成 App 图标：swiftc -O Design/make-app-icon.swift -o /tmp/make-icon && /tmp/make-icon SSH/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

// XR 终端图标：X 的左半边发光 = ">"，右半边暗 = 仍能看出 X；R 后面跟一个发光光标 "_"
let size = 1024
// 不带透明通道的画布（App Store 要求图标不透明）
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// 换成左上角为原点
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let mint = rgb(0x3DF5A8), cyan = rgb(0x1AB8FF)
let accent = CGGradient(colorsSpace: space, colors: [mint, cyan] as CFArray, locations: [0, 1])!

// 背景：深蓝到黑的斜向渐变 + 左上角一点柔光
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1A2535), rgb(0x0A0F17), rgb(0x030508)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: size, y: size), options: [])
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x3DF5A8, 0.10), rgb(0x3DF5A8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 470), endRadius: 460, options: [])

/// 用渐变描一条路径，并带一圈同色辉光
func strokeGlowing(_ path: CGPath, width: CGFloat, from: CGPoint, to: CGPoint) {
    let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 32, color: rgb(0x2EE6C0, 0.55))
    ctx.addPath(outline); ctx.setFillColor(mint); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(outline); ctx.clip()
    ctx.drawLinearGradient(accent, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// 字母组：更小，更靠左
let lineW: CGFloat = 21
let top: CGFloat = 470, bottom: CGFloat = 554, mid = (top + bottom) / 2

func plain(_ path: CGPath, alpha: CGFloat = 0.9) {
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: lineW, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.setFillColor(rgb(0xFFFFFF, alpha)); ctx.fillPath()
    ctx.restoreGState()
}

// 整组放大并往右挪：以字母组左边中点为基准缩放，再平移到新的位置
let groupScale: CGFloat = 1.55
ctx.saveGState()
ctx.translateBy(x: 212, y: mid)
ctx.scaleBy(x: groupScale, y: groupScale)
ctx.translateBy(x: -140, y: -mid)

// X：又高又窄，两条线几乎竖着交叉（上下夹角很小），少右上那一截
let xL: CGFloat = 140, xR: CGFloat = 178, xH: CGFloat = bottom - top, xC = (xL + xR) / 2
let x = CGMutablePath()
x.move(to: CGPoint(x: xL, y: mid - xH / 2)); x.addLine(to: CGPoint(x: xR, y: mid + xH / 2))
// 第二笔越过交叉点继续往右上，只在快到头的地方停住，右上只少一小截
let reach: CGFloat = 0.55
x.move(to: CGPoint(x: xL, y: mid + xH / 2))
x.addLine(to: CGPoint(x: xC + (xR - xC) * reach, y: mid - (xH / 2) * reach))
plain(x)

// R：竖线和腿白色，上半部分是发光的 ">"
let rL: CGFloat = 216, bowlBottom: CGFloat = top + 68, apex = CGPoint(x: rL + 58, y: (top + bowlBottom) / 2)
let stemAndLeg = CGMutablePath()
stemAndLeg.move(to: CGPoint(x: rL, y: bottom)); stemAndLeg.addLine(to: CGPoint(x: rL, y: top))
stemAndLeg.move(to: CGPoint(x: rL + 20, y: bowlBottom)); stemAndLeg.addLine(to: CGPoint(x: rL + 54, y: bottom))
plain(stemAndLeg)
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: rL, y: top))
chevron.addLine(to: apex)
chevron.addLine(to: CGPoint(x: rL, y: bowlBottom))
strokeGlowing(chevron, width: 26, from: CGPoint(x: rL, y: top), to: CGPoint(x: apex.x, y: bowlBottom))

// 光标 "_"
let uL = rL + 88, uR = uL + 40
let underscore = CGMutablePath()
underscore.move(to: CGPoint(x: uL, y: bottom)); underscore.addLine(to: CGPoint(x: uR, y: bottom))
strokeGlowing(underscore, width: 26, from: CGPoint(x: uL, y: 0), to: CGPoint(x: uR, y: 0))

ctx.restoreGState()
NSGraphicsContext.current = nil
let out = CommandLine.arguments[1]
let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)

