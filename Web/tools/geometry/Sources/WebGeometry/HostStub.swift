// On the Mac the page is not there: Skia's path operations are not checked here.
public enum Host {
    public enum Function: Int32 { case pathOp = 1, image, textLayout, log }
    public static func call(_ f: Function, doubles: [Double]) -> [Double] { [] }
}
