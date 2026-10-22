import Foundation

/// Стек отмены, ≤ 50 шагов. Мазок/тяга запоминаются по мазкам (какой мазок каким был до операции), очистка — снимком.
/// По мазкам, а не снимком всего списка, потому что две руки рисуют одновременно: отмена одного мазка
/// не должна откатывать мазок другой руки.
struct SculptUndo {
    enum Op: String { case add = "мазок", edit = "вытягивание", clear = "очистка" }
    private enum Entry {
        /// id мазка → каким он был (nil — его не было).
        case strokes(Op, [(Int, StrokeData?)])
        case all(Op, [StrokeData])
    }
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    let limit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private mutating func record(_ e: Entry) {
        undoStack.append(e)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// Снимок всего списка до операции (очистка).
    mutating func push(_ op: Op, before: [StrokeData]) { record(.all(op, before)) }

    /// Операция над отдельными мазками закончена: какими они были до неё (nil — мазка не было).
    mutating func pushStrokes(_ op: Op, before: [(Int, StrokeData?)]) { record(.strokes(op, before)) }

    private static func apply(_ ch: [(Int, StrokeData?)], to list: [StrokeData]) -> [StrokeData] {
        var out = list
        for (id, v) in ch {
            if let i = out.firstIndex(where: { $0.id == id }) {
                if let v { out[i] = v } else { out.remove(at: i) }
            } else if let v {
                out.append(v)
            }
        }
        return out
    }

    private static func invert(_ e: Entry, current: [StrokeData]) -> (Entry, Op, [StrokeData]) {
        switch e {
        case .all(let op, let s):
            return (.all(op, current), op, s)
        case .strokes(let op, let ch):
            let back = ch.map { (id, _) in (id, current.first { $0.id == id }) }
            return (.strokes(op, back), op, apply(ch, to: current))
        }
    }

    /// Отмена: вернуть прежнее состояние, текущее — в «вернуть».
    mutating func undo(current: [StrokeData]) -> (Op, [StrokeData])? {
        guard let e = undoStack.popLast() else { return nil }
        let (inv, op, s) = SculptUndo.invert(e, current: current)
        redoStack.append(inv)
        return (op, s)
    }

    mutating func redo(current: [StrokeData]) -> (Op, [StrokeData])? {
        guard let e = redoStack.popLast() else { return nil }
        let (inv, op, s) = SculptUndo.invert(e, current: current)
        undoStack.append(inv)
        return (op, s)
    }
}
