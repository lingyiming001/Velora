import Foundation

/// Preserve editable fractions, scripts, roots and matrices in Word's native equation format.
enum MathMLToOfficeMath {
    private final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(_ name: String, _ attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
        var plain: String { text + children.map(\.plain).joined() }
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            let node = Node(name.components(separatedBy: ":").last ?? name, attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters text: String) { stack.last?.text += text }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func convert(_ xml: String) -> String {
        let reader = Reader(), parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = reader.root else { return "" }
        func tag(_ name: String, _ value: String) -> String { "<m:\(name)>\(value)</m:\(name)>" }
        func render(_ node: Node) -> String {
            let children = node.children.filter { $0.name != "annotation" && $0.name != "annotation-xml" }
            let all = { children.map(render).joined() }
            func child(_ index: Int) -> String { children.indices.contains(index) ? render(children[index]) : "" }
            switch node.name {
            case "annotation", "annotation-xml": return ""
            case "mi", "mn", "mo", "mtext", "ms":
                let properties = node.name == "mtext" || node.attributes["mathvariant"] == "normal" ? "<m:rPr><m:nor/></m:rPr>" : ""
                return "<m:r>" + properties + "<m:t xml:space=\"preserve\">" + escape(node.plain) + "</m:t></m:r>"
            case "mfrac": return tag("f", tag("num", child(0)) + tag("den", child(1)))
            case "msup": return tag("sSup", tag("e", child(0)) + tag("sup", child(1)))
            case "msub": return tag("sSub", tag("e", child(0)) + tag("sub", child(1)))
            case "msubsup": return tag("sSubSup", tag("e", child(0)) + tag("sub", child(1)) + tag("sup", child(2)))
            case "msqrt": return "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/>" + tag("e", all()) + "</m:rad>"
            case "mroot": return tag("rad", tag("deg", child(1)) + tag("e", child(0)))
            case "mover":
                if node.attributes["accent"] == "true", children.count > 1 {
                    return "<m:acc><m:accPr><m:chr m:val=\"" + escape(children[1].plain) + "\"/></m:accPr>" + tag("e", child(0)) + "</m:acc>"
                }
                return tag("limUpp", tag("e", child(0)) + tag("lim", child(1)))
            case "munder": return tag("limLow", tag("e", child(0)) + tag("lim", child(1)))
            case "munderover": return tag("limUpp", tag("e", tag("limLow", tag("e", child(0)) + tag("lim", child(1)))) + tag("lim", child(2)))
            case "mtable": return tag("m", children.map { row in tag("mr", row.children.map { tag("e", render($0)) }.joined()) }.joined())
            case "mfenced":
                return "<m:d><m:dPr><m:begChr m:val=\"" + escape(node.attributes["open"] ?? "(") + "\"/><m:endChr m:val=\"" + escape(node.attributes["close"] ?? ")") + "\"/></m:dPr>" + tag("e", all()) + "</m:d>"
            case "mspace": return "<m:r><m:t xml:space=\"preserve\"> </m:t></m:r>"
            default:
                if let first = children.first, let last = children.last, children.count >= 3,
                   first.name == "mo", last.name == "mo",
                   ["(", "[", "{", "|", "‖"].contains(first.plain), [")", "]", "}", "|", "‖"].contains(last.plain) {
                    return "<m:d><m:dPr><m:begChr m:val=\"" + escape(first.plain) + "\"/><m:endChr m:val=\"" + escape(last.plain) + "\"/></m:dPr><m:e>" + children.dropFirst().dropLast().map(render).joined() + "</m:e></m:d>"
                }
                return all()
            }
        }
        return "<m:oMath>" + render(root) + "</m:oMath>"
    }
    static func latex(fromOfficeMath xml: String) -> String {
        let reader = Reader(), parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = reader.root else { return "" }
        func render(_ node: Node) -> String {
            func item(_ name: String) -> String { node.children.first { $0.name == name }.map(render) ?? "" }
            func all() -> String { node.children.map(render).joined() }
            switch node.name {
            case "f": return #"\frac{"# + item("num") + "}{" + item("den") + "}"
            case "sSup": return "{" + item("e") + "}^{" + item("sup") + "}"
            case "sSub": return "{" + item("e") + "}_{" + item("sub") + "}"
            case "sSubSup": return "{" + item("e") + "}_{" + item("sub") + "}^{" + item("sup") + "}"
            case "rad":
                let degree = item("deg")
                return (degree.isEmpty ? #"\sqrt{"# : #"\sqrt["# + degree + "]{") + item("e") + "}"
            case "limLow": return "{" + item("e") + "}_{" + item("lim") + "}"
            case "limUpp": return "{" + item("e") + "}^{" + item("lim") + "}"
            case "m": return #"\begin{matrix}"# + node.children.filter { $0.name == "mr" }.map(render).joined(separator: #"\\"#) + #"\end{matrix}"#
            case "mr": return node.children.filter { $0.name == "e" }.map(render).joined(separator: " & ")
            case "r":
                if node.children.contains(where: { $0.name == "rPr" && $0.children.contains(where: { $0.name == "nor" }) }) {
                    return #"\text{"# + node.children.filter { $0.name == "t" }.map(\.plain).joined().replacingOccurrences(of: "}", with: #"\}"#) + "}"
                }
                return all()
            case "t":
                var value = node.text
                for (symbol, command) in [("∫", #"\int "#), ("∑", #"\sum "#), ("∞", #"\infty "#), ("×", #"\times "#), ("−", "-"), ("≤", #"\le "#), ("≥", #"\ge "#)] {
                    value = value.replacingOccurrences(of: symbol, with: command)
                }
                return value
            case "d":
                let properties = node.children.first { $0.name == "dPr" }
                let left = properties?.children.first { $0.name == "begChr" }?.attributes["m:val"] ?? "("
                let right = properties?.children.first { $0.name == "endChr" }?.attributes["m:val"] ?? ")"
                return left + item("e") + right
            case "acc": return #"\hat{"# + item("e") + "}"
            default: return node.name.hasSuffix("Pr") ? "" : all()
            }
        }
        return render(root)
    }

}
