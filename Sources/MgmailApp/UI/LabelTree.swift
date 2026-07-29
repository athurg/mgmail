import Foundation

/// 标签层级树的节点（Gmail 用 "/" 表示嵌套）。
struct LabelNode: Identifiable {
    let id: String           // 完整路径，如 "8.子邮箱/itadmin@x"
    let title: String        // 末段名，如 "itadmin@x"
    let label: GmailLabel?   // 对应的真实标签（存在则可选中；纯中间层为 nil）
    let children: [LabelNode]
}

/// 把扁平的用户标签按 "/" 解析成层级树。
enum LabelTree {
    private final class Node {
        let path: String
        let title: String
        var label: GmailLabel?
        var children: [Node] = []
        init(path: String, title: String) {
            self.path = path
            self.title = title
        }
    }

    static func build(_ labels: [GmailLabel]) -> [LabelNode] {
        var index: [String: Node] = [:]
        var rootOrder: [String] = []

        let sorted = labels.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        for label in sorted {
            let parts = label.name.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var prefix = ""
            var parentPath: String?
            for (i, part) in parts.enumerated() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                if index[prefix] == nil {
                    let node = Node(path: prefix, title: part)
                    index[prefix] = node
                    if let pp = parentPath, let parent = index[pp] {
                        parent.children.append(node)
                    } else {
                        rootOrder.append(prefix)
                    }
                }
                if i == parts.count - 1 { index[prefix]?.label = label }
                parentPath = prefix
            }
        }

        func convert(_ node: Node) -> LabelNode {
            LabelNode(id: node.path, title: node.title, label: node.label,
                      children: node.children.map(convert))
        }
        return rootOrder.compactMap { index[$0] }.map(convert)
    }
}

/// 侧栏展开/折叠状态的持久化。
enum LabelExpansionStore {
    private static let key = "expandedLabels.v1"          // 标签树节点：默认折叠，记录“已展开”
    private static let collapsedKey = "collapsedGroups.v1" // 固定邮箱/账户分组：默认展开，记录“已折叠”

    /// 标签树节点的已展开集合（默认折叠）。
    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ expanded: Set<String>) {
        UserDefaults.standard.set(Array(expanded), forKey: key)
    }

    /// 固定邮箱/账户分组的已折叠集合（默认展开）。
    static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }

    static func saveCollapsed(_ collapsed: Set<String>) {
        UserDefaults.standard.set(Array(collapsed), forKey: collapsedKey)
    }
}
