import SheetMusicFoundation

extension PDFSourceDocument {
    func pages() throws -> [PDFSourcePage] {
        guard let root = trailer["Root"], let catalog = try resolve(root).dictionary,
              let tree = catalog["Pages"] else { throw PDFAppendError.unreadable }
        var visited: Set<Int> = []
        var pages: [PDFSourcePage] = []
        try walk(tree, inherited: [:], depth: 0, visited: &visited, pages: &pages)
        return pages
    }

    private func walk(
        _ value: PDFSourceValue,
        inherited: [String: PDFSourceValue],
        depth: Int,
        visited: inout Set<Int>,
        pages: inout [PDFSourcePage],
    ) throws {
        guard depth < 64, case let .reference(number, generation) = value,
              visited.insert(number).inserted, let dictionary = try resolve(value).dictionary
        else {
            throw PDFAppendError.unreadable
        }
        var attributes = inherited
        for key in ["MediaBox", "CropBox", "Rotate"] {
            if let item = dictionary[key] { attributes[key] = try resolve(item) }
        }
        if dictionary["Type"] == .name("Page") || dictionary["Kids"] == nil {
            try pages.append(PDFSourcePage(
                number: number,
                generation: generation,
                dictionary: dictionary,
                space: space(attributes),
            ))
            return
        }
        guard let kids = dictionary["Kids"], let children = try resolve(kids).array else {
            throw PDFAppendError.unreadable
        }
        for child in children {
            try walk(child, inherited: attributes, depth: depth + 1, visited: &visited, pages: &pages)
        }
    }

    private func space(_ attributes: [String: PDFSourceValue]) throws -> PDFPageSpace {
        let media = try box(attributes["MediaBox"]) ?? [0, 0, 612, 792]
        let crop = try box(attributes["CropBox"]) ?? media
        let left = max(media[0], crop[0]), bottom = max(media[1], crop[1])
        let right = max(left, min(media[2], crop[2])), top = max(bottom, min(media[3], crop[3]))
        guard (right - left).isFinite, (top - bottom).isFinite else { throw PDFAppendError.unreadable }
        return PDFPageSpace(
            left: left,
            bottom: bottom,
            right: right,
            top: top,
            rotation: attributes["Rotate"]?.integer ?? 0,
        )
    }

    private func box(_ value: PDFSourceValue?) throws -> [Double]? {
        guard let value else { return nil }
        guard let coordinates = try resolve(value).array, coordinates.count == 4 else {
            throw PDFAppendError.unreadable
        }
        let numbers = try coordinates.map { coordinate in
            guard let number = try resolve(coordinate).numeric, number.isFinite else {
                throw PDFAppendError.unreadable
            }
            return number
        }
        return [
            min(numbers[0], numbers[2]),
            min(numbers[1], numbers[3]),
            max(numbers[0], numbers[2]),
            max(numbers[1], numbers[3]),
        ]
    }
}
