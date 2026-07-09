import SwiftUI

struct ElementInspector: View {
    @ObservedObject var store: DevToolsStore
    let onStartPicking: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            inspectorToolbar
            Divider()
            if store.isInspectingElement {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Click on an element to inspect")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let element = store.inspectedElement {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        elementSummary(element)
                        Divider()
                        attributesSection(element.attributes)
                        if !element.cssProperties.isEmpty {
                            Divider()
                            cssSection(element.cssProperties)
                        }
                        Divider()
                        computedStyleSection(element.computedStyle)
                        Divider()
                        htmlSection(element.outerHTML)
                    }
                    .padding(12)
                }
            } else {
                EmptyState(message: "No element selected")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inspectorToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder")
                .foregroundStyle(.secondary)

            Button {
                onStartPicking()
            } label: {
                Text("Pick Element")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer()

            if let element = store.inspectedElement {
                Text(element.tagName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func elementSummary(_ element: InspectedElement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(element.tagName.uppercased())
                    .font(.system(size: 16, weight: .bold))
                if let id = element.attributes["id"] {
                    Text("#\(id)")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                }
                if let classes = element.attributes["class"] {
                    let classList = classes.split(separator: " ").map { ".\($0)" }.joined(separator: " ")
                    Text(classList)
                        .font(.system(size: 14))
                        .foregroundStyle(.purple)
                        .lineLimit(2)
                }
            }

            if let xpath = element.xpath {
                HStack(spacing: 4) {
                    Text("XPath:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(xpath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let bbox = element.boundingBox {
                HStack(spacing: 4) {
                    Text("Size:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(Int(bbox.width)) × \(Int(bbox.height)) px")
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func attributesSection(_ attributes: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attributes")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                ForEach(attributes.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 4) {
                        Text(key)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.blue)
                        Text("=")
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private func cssSection(_ properties: [InspectedElement.CSSProperty]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CSS Properties")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                ForEach(properties, id: \.name) { prop in
                    HStack(alignment: .top, spacing: 4) {
                        Text(prop.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.purple)
                        Text(":")
                            .foregroundStyle(.secondary)
                        Text(prop.value)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                        if prop.important {
                            Text("!important")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    private func computedStyleSection(_ style: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computed Style")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                ForEach(style.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 4) {
                        Text(key)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(":")
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func htmlSection(_ html: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HTML")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
                Text(html)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
        }
    }
}

#Preview {
    let store = DevToolsStore()
    let element = InspectedElement(
        tagName: "div",
        attributes: ["id": "main", "class": "container active"],
        innerHTML: "Hello World",
        outerHTML: "<div id=\"main\" class=\"container active\">Hello World</div>",
        cssProperties: [
            InspectedElement.CSSProperty(name: "background-color", value: "white", important: false, source: "style.css"),
            InspectedElement.CSSProperty(name: "padding", value: "10px", important: true, source: "style.css")
        ],
        computedStyle: ["display": "block", "position": "relative"],
        boundingBox: InspectedElement.BoundingBox(x: 0, y: 0, width: 100, height: 50),
        selector: "#main",
        xpath: "/html/body/div[@id='main']"
    )
    store.setInspectedElement(element)
    return ElementInspector(store: store, onStartPicking: {})
        .frame(width: 400, height: 600)
}