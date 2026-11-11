// Unit check for HIDDescriptorParser. Build together with RawButtonMonitor.swift:
//   swiftc -parse-as-library -o parser_test RawButtonMonitor.swift parser_test.swift && ./parser_test
import Foundation
func hex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { i in
    let a = s.index(s.startIndex, offsetBy: i); return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)! } }

@main
enum ParserTest {
    static func main() {
        var failures = 0
            func check(_ name: String, _ got: [HIDButtonField], _ wantUnnamed: [Int], reportID: UInt8) {
            let quirky = got.filter { !$0.unnamedBitPositions.isEmpty }
            let unnamed = quirky.flatMap { $0.unnamedBitPositions }
            let ok = unnamed == wantUnnamed && (wantUnnamed.isEmpty || quirky.allSatisfy { $0.reportID == reportID })
            if !ok { failures += 1 }
            print(ok ? "PASS" : "FAIL", name, "fields:", got.map { "id=\($0.reportID) off=\($0.bitOffset) count=\($0.count) named=\($0.namedCount)" }, "unnamed bits:", unnamed)
        }
        // 1. The user's Delux "Wireless Receiver" 248a:8566 mouse interface (from ioreg)
        let delux = hex("05010902a10185010901a1000509190129031500250175019505810275039501810105010930093116018026ff7f75109502810609381581257f750895018106c0c0050c0901a1018502751095011501268c0219012a8c028100c005010980a1018503098209810983150025011901290375019503810295058101c005010900a10185050600ff09011581257f75089507b102c0")
        check("Delux receiver (5 bits, usages 1-3)", HIDDescriptorParser.buttonFields(in: delux), [3, 4], reportID: 1)
        // 2. A typical complete 5-button mouse: usages 1-5, no report ID
        let normal = hex("05010902a1010901a1000509190129051500250195057501810295017503810105010930093109381581257f750895038106c0c0")
        check("Standard 5-button mouse (usages 1-5)", HIDDescriptorParser.buttonFields(in: normal), [], reportID: 0)
        // 3. Basic 3-button mouse with 5 bits but 2 constant padding bits declared as constant
        let threeBtn = hex("05010902a1010901a10005091901290315002501950375018102950175058101050109300931150025ff750895028106c0c0")
        check("3-button mouse with constant padding", HIDDescriptorParser.buttonFields(in: threeBtn), [], reportID: 0)
        // 4. Keyboard-side descriptor from the other receiver interface (report 6 mouse, usages 1-3, 5 bits)
        let kbdSide = hex("050c0901a101850319002a3c031500263c03950175108100c005010980a101850205011981298315002501950375018102950175058101c005010906a101850105071500250119002977957875018102c005010902a10185060901a1000509190129031500250195057501810295017503810105010930093109381581257f750895038106050c0a380295018106c0c0")
        check("Gaming keyboard mouse collection (report 6)", HIDDescriptorParser.buttonFields(in: kbdSide), [3, 4], reportID: 6)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
