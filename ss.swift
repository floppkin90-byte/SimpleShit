import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

let SIMPLESHIT_VERSION = "1.1.1 Stable"

// ============ Errors ============
enum SimpleShitError: Error, CustomStringConvertible {
    case lex(String, line: Int, col: Int)
    case parse(String, line: Int)
    case runtime(String, line: Int)
    var description: String {
        switch self {
        case .lex(let m, let l, let c): return "Lex error at \(l):\(c): \(m)"
        case .parse(let m, let l):      return "Parse error at line \(l): \(m)"
        case .runtime(let m, let l):    return "Runtime error at line \(l): \(m)"
        }
    }
}

// ============ Runtime objects ============
final class TableRef {
    var entries: [(key: Value, value: Value)]
    init(_ e: [(key: Value, value: Value)] = []) { entries = e }
}

final class ArrayRef {
    var items: [Value]
    init(_ i: [Value] = []) { items = i }
}

struct Function {
    let params: [String]
    let body: [Stmt]
    let closure: Env
}

// ============ Value ============
enum Value: CustomStringConvertible {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    case function(Function)
    case table(TableRef)
    case array(ArrayRef)
    case range(start: Int, end: Int, inclusive: Bool)

    var description: String {
        switch self {
        case .number(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .string(let s): return s
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        case .function:      return "<function>"
        case .table(let t):
            let inner = t.entries.map { "\($0.key.description): \($0.value.description)" }
                                .joined(separator: ", ")
            return "{\(inner)}"
        case .array(let a):
            let inner = a.items.map { $0.description }.joined(separator: ", ")
            return "[\(inner)]"
        case .range(let s, let e, let inc):
            return "\(s)..\(inc ? "=" : "")\(e)"
        }
    }

    var isTruthy: Bool {
        switch self {
        case .number(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .bool(let b):   return b
        case .null:          return false
        case .function:      return true
        case .table(let t):  return !t.entries.isEmpty
        case .array(let a):  return !a.items.isEmpty
        case .range:         return true
        }
    }

    var asNumber: Double? {
        switch self {
        case .number(let d): return d
        case .bool(let b):   return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var typeName: String {
        switch self {
        case .number:   return "number"
        case .string:   return "string"
        case .bool:     return "bool"
        case .null:     return "null"
        case .function: return "function"
        case .table:    return "table"
        case .array:    return "array"
        case .range:    return "range"
        }
    }
}

// ============ Environment ============
final class Env {
    var vars: [String: Value] = [:]
    weak var parent: Env?
    init(parent: Env? = nil) { self.parent = parent }
    func get(_ name: String) -> Value? {
        if let v = vars[name] { return v }
        return parent?.get(name)
    }
    @discardableResult
    func assign(_ name: String, _ v: Value) -> Bool {
        if vars[name] != nil { vars[name] = v; return true }
        if let p = parent, p.assign(name, v) { return true }
        return false
    }
    func define(_ name: String, _ v: Value) { vars[name] = v }
}

// ============ Lexer ============
enum TokenKind: Equatable {
    case number(Double)
    case string(String)
    case ident(String)
    case keyword(String)
    case op(String)
    case eof
}

struct Token { let kind: TokenKind; let line: Int; let col: Int }

final class Lexer {
    private let src: [Character]
    private var i = 0
    private var line = 1
    private var col = 1
    private let keywords: Set<String> = [
        "if","else","elseif","while","for","in",
        "func","fn","return","true","false","null",
        "break","continue","print","match","case","default"
    ]

    init(_ source: String) { self.src = Array(source) }

    func tokenize() throws -> [Token] {
        var out: [Token] = []
        while true {
            skipWhitespaceAndComments()
            if i >= src.count { break }
            let c = src[i]
            let sl = line, sc = col
            if c.isNumber { out.append(try lexNumber(sl, sc)) }
            else if c == "\"" { out.append(try lexString(sl, sc)) }
            else if c.isLetter || c == "_" { out.append(lexIdent(sl, sc)) }
            else { out.append(try lexOp(sl, sc)) }
        }
        out.append(Token(kind: .eof, line: line, col: col))
        return out
    }

    private func advance() {
        if src[i] == "\n" { line += 1; col = 1 } else { col += 1 }
        i += 1
    }

    private func skipWhitespaceAndComments() {
        while i < src.count {
            let c = src[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" { advance() }
            else if c == "#" { while i < src.count && src[i] != "\n" { advance() } }
            else if c == "/" && i + 1 < src.count && src[i+1] == "/" {
                while i < src.count && src[i] != "\n" { advance() }
            } else { break }
        }
    }

    private func lexNumber(_ l: Int, _ c: Int) throws -> Token {
        var s = ""
        while i < src.count && (src[i].isNumber || src[i] == ".") {
            if src[i] == "." {
                // `.` — часть числа только если следующая — цифра.
                // Иначе это `..` (range) или `.method` (member access).
                if i + 1 >= src.count || !src[i+1].isNumber { break }
            }
            s.append(src[i]); advance()
        }
        guard let d = Double(s) else {
            throw SimpleShitError.lex("bad number '\(s)'", line: l, col: c)
        }
        return Token(kind: .number(d), line: l, col: c)
    }

    private func lexString(_ l: Int, _ c: Int) throws -> Token {
        advance()
        var s = ""
        while i < src.count && src[i] != "\"" {
            if src[i] == "\\" {
                advance()
                if i >= src.count { throw SimpleShitError.lex("unterminated escape", line: l, col: c) }
                switch src[i] {
                case "n": s.append("\n")
                case "t": s.append("\t")
                case "r": s.append("\r")
                case "\"": s.append("\"")
                case "\\": s.append("\\")
                default:  s.append(src[i])
                }
                advance()
            } else { s.append(src[i]); advance() }
        }
        if i >= src.count { throw SimpleShitError.lex("unterminated string", line: l, col: c) }
        advance()
        return Token(kind: .string(s), line: l, col: c)
    }

    private func lexIdent(_ l: Int, _ c: Int) -> Token {
        var s = ""
        while i < src.count && (src[i].isLetter || src[i].isNumber || src[i] == "_") {
            s.append(src[i]); advance()
        }
        return Token(kind: keywords.contains(s) ? .keyword(s) : .ident(s), line: l, col: c)
    }

    private func lexOp(_ l: Int, _ c: Int) throws -> Token {
        if i + 2 < src.count {
            let three = String([src[i], src[i+1], src[i+2]])
            if three == "..=" {
                advance(); advance(); advance()
                return Token(kind: .op("..="), line: l, col: c)
            }
        }
        let two = i + 1 < src.count ? String([src[i], src[i+1]]) : ""
        let twoOps: Set<String> = ["==","!=","<=",">=","&&","||","..","+=","-=","*=","/="]
        if twoOps.contains(two) {
            advance(); advance()
            return Token(kind: .op(two), line: l, col: c)
        }
        let one = String(src[i])
        let oneOps: Set<String> = ["+","-","*","/","%","<",">","!","=","(",")","{","}",",",".",";",":","[","]","?"]
        if oneOps.contains(one) {
            advance()
            return Token(kind: .op(one), line: l, col: c)
        }
        throw SimpleShitError.lex("unexpected '\(one)'", line: l, col: c)
    }
}

// ============ AST ============
indirect enum Expr {
    case literal(Value)
    case variable(String)
    case binary(Expr, String, Expr)
    case unary(String, Expr)
    case assign(String, Expr)
    case tableSet(Expr, Expr, Expr)
    case ternary(Expr, Expr, Expr)
    case call(Expr, [Expr])
    case member(Expr, String)
    case tableLiteral([(Value, Expr)])
    case arrayLiteral([Expr])
    case functionLiteral([String], [Stmt])
}

struct Stmt {
    let kind: StmtKind
    let line: Int
}

indirect enum StmtKind {
    case expr(Expr)
    case printStmt([Expr])
    case ifChain([(Expr, [Stmt])], [Stmt]?)
    case whileStmt(Expr, [Stmt])
    case forStmt([String], Expr, [Stmt])
    case matchStmt(Expr, [(patterns: [Expr], body: [Stmt])], [Stmt]?)
    case funcDecl(String, [String], [Stmt])
    case returnStmt(Expr?)
    case breakStmt
    case continueStmt
}

// ============ Parser ============
final class Parser {
    private let tokens: [Token]
    private var i = 0
    init(_ tokens: [Token]) { self.tokens = tokens }

    private var peek: Token { tokens[i] }
    private func check(_ k: TokenKind) -> Bool { peek.kind == k }
    private func isOp(_ s: String) -> Bool {
        if case .op(let o) = peek.kind { return o == s }; return false
    }
    private func isKeyword(_ k: String) -> Bool {
        if case .keyword(let kw) = peek.kind { return kw == k }; return false
    }
    private func matchOp(_ s: String) -> Bool { if isOp(s) { i += 1; return true }; return false }
    private func matchKeyword(_ k: String) -> Bool { if isKeyword(k) { i += 1; return true }; return false }
    private func consumeOp(_ s: String, _ msg: String) throws {
        if isOp(s) { i += 1; return }
        throw SimpleShitError.parse(msg, line: peek.line)
    }
    private func consumeIdent(_ msg: String) throws -> String {
        if case .ident(let n) = peek.kind { i += 1; return n }
        throw SimpleShitError.parse(msg, line: peek.line)
    }

    func parse() throws -> [Stmt] {
        var stmts: [Stmt] = []
        while !check(.eof) {
            if matchOp(";") { continue }
            stmts.append(try statement())
        }
        return stmts
    }

    func parseExpression() throws -> Expr {
        let e = try expression()
        if !check(.eof) { throw SimpleShitError.parse("unexpected trailing tokens", line: peek.line) }
        return e
    }

    private func statement() throws -> Stmt {
        let line = peek.line
        if isKeyword("print") {
            i += 1
            var exprs: [Expr] = []
            repeat { exprs.append(try expression()) } while matchOp(",")
            return Stmt(kind: .printStmt(exprs), line: line)
        }
        if isKeyword("if")    { return Stmt(kind: try ifStatement(),    line: line) }
        if isKeyword("while") { return Stmt(kind: try whileStatement(), line: line) }
        if isKeyword("for")   { return Stmt(kind: try forStatement(),   line: line) }
        if isKeyword("match") { return Stmt(kind: try matchStatement(), line: line) }
        if isKeyword("func") || isKeyword("fn") { return Stmt(kind: try funcDecl(), line: line) }
        if isKeyword("return") {
            i += 1
            if isOp("}") || isOp(";") || check(.eof) {
                return Stmt(kind: .returnStmt(nil), line: line)
            }
            return Stmt(kind: .returnStmt(try expression()), line: line)
        }
        if isKeyword("break")    { i += 1; return Stmt(kind: .breakStmt, line: line) }
        if isKeyword("continue") { i += 1; return Stmt(kind: .continueStmt, line: line) }
        return Stmt(kind: .expr(try expression()), line: line)
    }

    private func block() throws -> [Stmt] {
        try consumeOp("{", "expected '{'")
        var stmts: [Stmt] = []
        while !isOp("}") && !check(.eof) {
            if matchOp(";") { continue }
            stmts.append(try statement())
        }
        try consumeOp("}", "expected '}'")
        return stmts
    }

    private func ifStatement() throws -> StmtKind {
        i += 1
        var branches: [(Expr, [Stmt])] = []
        branches.append((try expression(), try block()))
        var elseBody: [Stmt]? = nil
        while true {
            if isKeyword("else") {
                i += 1
                if isKeyword("if") {
                    i += 1
                    branches.append((try expression(), try block()))
                } else {
                    elseBody = try block()
                    break
                }
            } else if isKeyword("elseif") {
                i += 1
                branches.append((try expression(), try block()))
            } else { break }
        }
        return .ifChain(branches, elseBody)
    }

    private func whileStatement() throws -> StmtKind {
        i += 1
        let cond = try expression()
        return .whileStmt(cond, try block())
    }

    private func forStatement() throws -> StmtKind {
        i += 1
        var names: [String] = [try consumeIdent("expected loop variable")]
        while matchOp(",") {
            names.append(try consumeIdent("expected loop variable"))
        }
        if !matchKeyword("in") {
            throw SimpleShitError.parse("expected 'in' in for-loop", line: peek.line)
        }
        let iter = try expression()
        return .forStmt(names, iter, try block())
    }

    private func matchStatement() throws -> StmtKind {
        i += 1
        let subject = try expression()
        try consumeOp("{", "expected '{' in match")
        var cases: [(patterns: [Expr], body: [Stmt])] = []
        var defaultBody: [Stmt]? = nil
        while !isOp("}") && !check(.eof) {
            if isKeyword("case") {
                i += 1
                var patterns: [Expr] = []
                patterns.append(try expression())
                while matchOp(",") { patterns.append(try expression()) }
                cases.append((patterns, try block()))
            } else if isKeyword("default") {
                i += 1
                defaultBody = try block()
            } else {
                throw SimpleShitError.parse("expected 'case' or 'default'", line: peek.line)
            }
        }
        try consumeOp("}", "expected '}'")
        return .matchStmt(subject, cases, defaultBody)
    }

    private func funcDecl() throws -> StmtKind {
        i += 1
        let name = try consumeIdent("expected function name")
        try consumeOp("(", "expected '('")
        var params: [String] = []
        if !isOp(")") {
            repeat { params.append(try consumeIdent("expected parameter name")) }
            while matchOp(",")
        }
        try consumeOp(")", "expected ')'")
        return .funcDecl(name, params, try block())
    }

    private func expression() throws -> Expr { try assignment() }

    private func assignment() throws -> Expr {
        let left = try ternary()
        if isOp("=") {
            i += 1
            let right = try assignment()
            if case .variable(let n) = left { return .assign(n, right) }
            if case .call(let callee, let args) = left,
               case .variable = callee, args.count == 1 {
                return .tableSet(callee, args[0], right)
            }
            throw SimpleShitError.parse("invalid assignment target", line: peek.line)
        }
        if isOp("+=") || isOp("-=") || isOp("*=") || isOp("/=") {
            let opFull: String; if case .op(let o) = peek.kind { opFull = o } else { opFull = "" }
            i += 1
            let right = try assignment()
            let binOp = String(opFull.dropLast())
            if case .variable(let n) = left {
                return .assign(n, .binary(.variable(n), binOp, right))
            }
            if case .call(let callee, let args) = left,
               case .variable = callee, args.count == 1 {
                let readBack = Expr.call(callee, args)
                return .tableSet(callee, args[0], .binary(readBack, binOp, right))
            }
            throw SimpleShitError.parse("invalid assignment target", line: peek.line)
        }
        return left
    }

    private func ternary() throws -> Expr {
        let cond = try range()
        if isOp("?") {
            i += 1
            let then = try ternary()
            try consumeOp(":", "expected ':' in ternary")
            let els = try ternary()
            return .ternary(cond, then, els)
        }
        return cond
    }

    private func range() throws -> Expr {
        var l = try or()
        while isOp("..") || isOp("..=") {
            let inclusive = isOp("..=")
            i += 1
            l = .binary(l, inclusive ? "..=" : "..", try or())
        }
        return l
    }

    private func or() throws -> Expr {
        var l = try and()
        while isOp("||") { i += 1; l = .binary(l, "||", try and()) }
        return l
    }
    private func and() throws -> Expr {
        var l = try equality()
        while isOp("&&") { i += 1; l = .binary(l, "&&", try equality()) }
        return l
    }
    private func equality() throws -> Expr {
        var l = try comparison()
        while true {
            if isOp("==") || isOp("!=") {
                let op: String; if case .op(let o) = peek.kind { op = o } else { op = "" }
                i += 1
                l = .binary(l, op, try comparison())
            } else if isKeyword("in") {
                i += 1
                l = .binary(l, "in", try range())
            } else {
                break
            }
        }
        return l
    }
    private func comparison() throws -> Expr {
        var l = try additive()
        while isOp("<") || isOp(">") || isOp("<=") || isOp(">=") {
            let op: String; if case .op(let o) = peek.kind { op = o } else { op = "" }
            i += 1; l = .binary(l, op, try additive())
        }
        return l
    }
    private func additive() throws -> Expr {
        var l = try multiplicative()
        while isOp("+") || isOp("-") {
            let op: String; if case .op(let o) = peek.kind { op = o } else { op = "" }
            i += 1; l = .binary(l, op, try multiplicative())
        }
        return l
    }
    private func multiplicative() throws -> Expr {
        var l = try unary()
        while isOp("*") || isOp("/") || isOp("%") {
            let op: String; if case .op(let o) = peek.kind { op = o } else { op = "" }
            i += 1; l = .binary(l, op, try unary())
        }
        return l
    }
    private func unary() throws -> Expr {
        if isOp("!") || isOp("-") {
            let op: String; if case .op(let o) = peek.kind { op = o } else { op = "" }
            i += 1; return .unary(op, try unary())
        }
        return try postfix()
    }
    private func postfix() throws -> Expr {
        var e = try primary()
        while true {
            if isOp("(") {
                i += 1
                var args: [Expr] = []
                if !isOp(")") { repeat { args.append(try expression()) } while matchOp(",") }
                try consumeOp(")", "expected ')'")
                e = .call(e, args)
            } else if isOp(".") {
                i += 1
                e = .member(e, try consumeIdent("expected member name"))
            } else { break }
        }
        return e
    }
    private func primary() throws -> Expr {
        if case .number(let d) = peek.kind { i += 1; return .literal(.number(d)) }
        if case .string(let s) = peek.kind { i += 1; return interpolate(s) }
        if case .ident(let n)  = peek.kind { i += 1; return .variable(n) }
        if matchKeyword("true")  { return .literal(.bool(true)) }
        if matchKeyword("false") { return .literal(.bool(false)) }
        if matchKeyword("null")  { return .literal(.null) }
        if isKeyword("fn") || isKeyword("func") {
            i += 1
            try consumeOp("(", "expected '(' after fn")
            var params: [String] = []
            if !isOp(")") {
                repeat { params.append(try consumeIdent("expected parameter name")) }
                while matchOp(",")
            }
            try consumeOp(")", "expected ')'")
            let body = try block()
            return .functionLiteral(params, body)
        }
        if isOp("(") {
            i += 1
            let e = try expression()
            try consumeOp(")", "expected ')'")
            return e
        }
        if isOp("[") {
            i += 1
            var items: [Expr] = []
            if !isOp("]") {
                repeat { items.append(try expression()) } while matchOp(",")
            }
            try consumeOp("]", "expected ']'")
            return .arrayLiteral(items)
        }
        if isOp("{") {
            i += 1
            var entries: [(Value, Expr)] = []
            if !isOp("}") {
                repeat {
                    let k = try expression()
                    try consumeOp(":", "expected ':' in table literal")
                    let v = try expression()
                    entries.append((try constEval(k), v))
                } while matchOp(",")
            }
            try consumeOp("}", "expected '}'")
            return .tableLiteral(entries)
        }
        throw SimpleShitError.parse("unexpected token", line: peek.line)
    }
    private func constEval(_ e: Expr) throws -> Value {
        if case .literal(let v) = e { return v }
        throw SimpleShitError.parse("table key must be a literal", line: peek.line)
    }

    private func interpolate(_ s: String) -> Expr {
        var parts: [Expr] = []
        var current = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "%" {
                let afterOpen = s.index(after: idx)
                if afterOpen < s.endIndex, let close = s[afterOpen...].firstIndex(of: "%") {
                    let ident = String(s[afterOpen..<close])
                    if isValidIdent(ident) {
                        if !current.isEmpty {
                            parts.append(.literal(.string(current)))
                            current = ""
                        }
                        parts.append(.variable(ident))
                        idx = s.index(after: close)
                        continue
                    }
                }
            }
            current.append(c)
            idx = s.index(after: idx)
        }
        if !current.isEmpty { parts.append(.literal(.string(current))) }
        if parts.isEmpty { return .literal(.string("")) }
        if parts.count == 1 { return parts[0] }
        var result = parts[0]
        for p in parts.dropFirst() { result = .binary(result, "+", p) }
        return result
    }

    private func isValidIdent(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

// ============ Flow ============
enum Flow {
    case normal, breakLoop, continueLoop
    case returnValue(Value)
}

// ============ Interpreter ============
final class Interpreter {
    let globals = Env()
    var currentLine = 0

    func run(_ stmts: [Stmt]) throws { _ = try execBlock(stmts, env: globals) }

    func runtimeErr(_ msg: String) -> SimpleShitError {
        return .runtime(msg, line: currentLine)
    }

    @discardableResult
    func exec(_ stmt: Stmt, env: Env) throws -> Flow {
        currentLine = stmt.line
        switch stmt.kind {
        case .expr(let e):
            _ = try eval(e, env: env); return .normal
        case .printStmt(let exprs):
            let vals = try exprs.map { try eval($0, env: env) }
            print(vals.map { $0.description }.joined(separator: " "))
            return .normal
        case .ifChain(let branches, let elseBody):
            for (cond, body) in branches {
                if try eval(cond, env: env).isTruthy {
                    return try execBlock(body, env: Env(parent: env))
                }
            }
            if let eb = elseBody { return try execBlock(eb, env: Env(parent: env)) }
            return .normal
        case .whileStmt(let c, let body):
            while try eval(c, env: env).isTruthy {
                let f = try execBlock(body, env: Env(parent: env))
                switch f {
                case .normal, .continueLoop: continue
                case .breakLoop:             return .normal
                case .returnValue:           return f
                }
            }
            return .normal
        case .forStmt(let names, let iterExpr, let body):
            let iter = try eval(iterExpr, env: env)
            if names.count == 1 {
                let name = names[0]
                let items: [Value]
                switch iter {
                case .range(let s, let e, let inc):
                    let hi = inc ? e : e - 1
                    items = s > hi ? [] : (s...hi).map { .number(Double($0)) }
                case .table(let t): items = t.entries.map { $0.value }
                case .array(let a): items = a.items
                case .string(let s): items = s.map { .string(String($0)) }
                default: throw runtimeErr("cannot iterate over \(iter)")
                }
                for item in items {
                    let iterEnv = Env(parent: env)
                    iterEnv.vars[name] = item
                    let f = try execBlock(body, env: iterEnv)
                    switch f {
                    case .normal, .continueLoop: continue
                    case .breakLoop:             return .normal
                    case .returnValue:           return f
                    }
                }
            } else if names.count == 2 {
                let k = names[0], v = names[1]
                switch iter {
                case .table(let t):
                    for (kk, vv) in t.entries {
                        let iterEnv = Env(parent: env)
                        iterEnv.vars[k] = kk
                        iterEnv.vars[v] = vv
                        let f = try execBlock(body, env: iterEnv)
                        switch f {
                        case .normal, .continueLoop: continue
                        case .breakLoop:             return .normal
                        case .returnValue:           return f
                        }
                    }
                case .array(let a):
                    for (idx, vv) in a.items.enumerated() {
                        let iterEnv = Env(parent: env)
                        iterEnv.vars[k] = .number(Double(idx))
                        iterEnv.vars[v] = vv
                        let f = try execBlock(body, env: iterEnv)
                        switch f {
                        case .normal, .continueLoop: continue
                        case .breakLoop:             return .normal
                        case .returnValue:           return f
                        }
                    }
                default:
                    throw runtimeErr("destructuring for expects table or array, got \(iter.typeName)")
                }
            } else {
                throw runtimeErr("for supports 1 or 2 loop variables, got \(names.count)")
            }
            return .normal
        case .matchStmt(let subject, let cases, let defaultBody):
            let val = try eval(subject, env: env)
            for (patterns, body) in cases {
                for p in patterns {
                    let patVal = try eval(p, env: env)
                    if matches(val, patVal) {
                        return try execBlock(body, env: Env(parent: env))
                    }
                }
            }
            if let db = defaultBody { return try execBlock(db, env: Env(parent: env)) }
            return .normal
        case .funcDecl(let n, let p, let b):
            env.define(n, .function(Function(params: p, body: b, closure: env)))
            return .normal
        case .returnStmt(let e):
            return .returnValue(try e.map { try eval($0, env: env) } ?? .null)
        case .breakStmt:    return .breakLoop
        case .continueStmt: return .continueLoop
        }
    }

    func execBlock(_ stmts: [Stmt], env: Env) throws -> Flow {
        for s in stmts {
            let f = try exec(s, env: env)
            if case .normal = f { continue }
            return f
        }
        return .normal
    }

    func matches(_ val: Value, _ pattern: Value) -> Bool {
        if case .range(let s, let e, let inc) = pattern, case .number(let n) = val {
            let ni = Int(n)
            return inc ? (ni >= s && ni <= e) : (ni >= s && ni < e)
        }
        return valuesEqual(val, pattern)
    }

    func eval(_ expr: Expr, env: Env) throws -> Value {
        switch expr {
        case .literal(let v): return v
        case .variable(let n):
            guard let v = env.get(n) else {
                throw runtimeErr("undefined variable '\(n)'")
            }
            return v
        case .assign(let n, let e):
            let v = try eval(e, env: env)
            if !env.assign(n, v) { env.define(n, v) }
            return v
        case .tableSet(let tableExpr, let keyExpr, let valueExpr):
            let base = try eval(tableExpr, env: env)
            let key  = try eval(keyExpr, env: env)
            let val  = try eval(valueExpr, env: env)
            return try setIndex(base, key, val)
        case .ternary(let c, let t, let e):
            if try eval(c, env: env).isTruthy { return try eval(t, env: env) }
            return try eval(e, env: env)
        case .unary(let op, let e):
            let v = try eval(e, env: env)
            switch op {
            case "!": return .bool(!v.isTruthy)
            case "-": return .number(-(v.asNumber ?? 0))
            default:  throw runtimeErr("unknown unary '\(op)'")
            }
        case .binary(let l, let op, let r):
            return try evalBinary(l, op, r, env: env)
        case .call(let callee, let args):
            return try evalCall(callee, args, env: env)
        case .member:
            throw runtimeErr("member access only valid in method call")
        case .tableLiteral(let entries):
            let ref = TableRef()
            for (k, ve) in entries {
                ref.entries.append((k, try eval(ve, env: env)))
            }
            return .table(ref)
        case .arrayLiteral(let items):
            let ref = ArrayRef()
            for i in items { ref.items.append(try eval(i, env: env)) }
            return .array(ref)
        case .functionLiteral(let params, let body):
            return .function(Function(params: params, body: body, closure: env))
        }
    }

    func evalCall(_ callee: Expr, _ argExprs: [Expr], env: Env) throws -> Value {
        // Special: json.parse / json.stringify as virtual namespace
        if case .member(let obj, let m) = callee,
           case .variable(let name) = obj,
           name == "json",
           env.get("json") == nil {
            if m == "parse" {
                guard argExprs.count == 1 else { throw runtimeErr("json.parse expects 1 arg") }
                let s = try eval(argExprs[0], env: env)
                return try jsonParse(s)
            }
            if m == "stringify" || m == "encode" {
                guard argExprs.count == 1 else { throw runtimeErr("json.stringify expects 1 arg") }
                let v = try eval(argExprs[0], env: env)
                return .string(try jsonEncode(v))
            }
        }
        if case .variable(let n) = callee, env.get(n) == nil {
            let args = try argExprs.map { try eval($0, env: env) }
            if let r = try callBuiltin(n, args) { return r }
        }
        if case .member(let obj, let m) = callee {
            let recv = try eval(obj, env: env)
            let args = try argExprs.map { try eval($0, env: env) }
            return try callMethod(recv, m, args, env: env)
        }
        let fv = try eval(callee, env: env)
        let args = try argExprs.map { try eval($0, env: env) }
        if case .table(let t) = fv {
            guard args.count == 1 else {
                throw runtimeErr("table index expects 1 argument")
            }
            return try getIndex(.table(t), args[0])
        }
        if case .array(let a) = fv {
            guard args.count == 1 else {
                throw runtimeErr("array index expects 1 argument")
            }
            return try getIndex(.array(a), args[0])
        }
        guard case .function(let fn) = fv else {
            throw runtimeErr("'\(callee)' is not callable")
        }
        if args.count != fn.params.count {
            throw runtimeErr("expected \(fn.params.count) args, got \(args.count)")
        }
        let callEnv = Env(parent: fn.closure)
        for (n, v) in zip(fn.params, args) { callEnv.define(n, v) }
        if case .returnValue(let v) = try execBlock(fn.body, env: callEnv) { return v }
        return .null
    }

    func getIndex(_ base: Value, _ key: Value) throws -> Value {
        switch base {
        case .table(let t):
            if case .number(let d) = key {
                let idx = Int(d)
                guard idx >= 0 && idx < t.entries.count else {
                    throw runtimeErr("table index \(idx) out of range (size \(t.entries.count))")
                }
                return t.entries[idx].value
            }
            for e in t.entries where valuesEqual(e.key, key) { return e.value }
            throw runtimeErr("key \(key.description) not found in table")
        case .array(let a):
            guard case .number(let d) = key else {
                throw runtimeErr("array index must be a number")
            }
            var idx = Int(d)
            if idx < 0 { idx = a.items.count + idx }
            guard idx >= 0 && idx < a.items.count else {
                throw runtimeErr("array index \(Int(d)) out of range (size \(a.items.count))")
            }
            return a.items[idx]
        default:
            throw runtimeErr("cannot index \(base.typeName)")
        }
    }

    func setIndex(_ base: Value, _ key: Value, _ newValue: Value) throws -> Value {
        switch base {
        case .table(let t):
            for i in 0..<t.entries.count where valuesEqual(t.entries[i].key, key) {
                t.entries[i].value = newValue
                return .table(t)
            }
            t.entries.append((key, newValue))
            return .table(t)
        case .array(let a):
            guard case .number(let d) = key else {
                throw runtimeErr("array index must be a number")
            }
            var idx = Int(d)
            if idx < 0 { idx = a.items.count + idx }
            if idx == a.items.count {
                a.items.append(newValue)
                return .array(a)
            }
            guard idx >= 0 && idx < a.items.count else {
                throw runtimeErr("array index \(Int(d)) out of range (size \(a.items.count))")
            }
            a.items[idx] = newValue
            return .array(a)
        default:
            throw runtimeErr("cannot index-assign \(base.typeName)")
        }
    }

    func callBuiltin(_ name: String, _ args: [Value]) throws -> Value? {
        switch name {
        case "len":
            switch args.first ?? .null {
            case .string(let s): return .number(Double(s.count))
            case .table(let t):  return .number(Double(t.entries.count))
            case .array(let a):  return .number(Double(a.items.count))
            case .range(let s, let e, let inc):
                return .number(Double(max(0, inc ? (e - s + 1) : (e - s))))
            default: return .number(0)
            }
        case "str": return .string((args.first ?? .null).description)
        case "int": return .number((args.first?.asNumber ?? 0).rounded(.towardZero))
        case "num": return .number(args.first?.asNumber ?? 0)
        case "type": return .string((args.first ?? .null).typeName)
        case "abs": return .number(abs(args.first?.asNumber ?? 0))
        case "sqrt": return .number((args.first?.asNumber ?? 0).squareRoot())
        case "floor": return .number((args.first?.asNumber ?? 0).rounded(.down))
        case "ceil":  return .number((args.first?.asNumber ?? 0).rounded(.up))
        case "round": return .number((args.first?.asNumber ?? 0).rounded())
        case "min":
            let ns = args.compactMap { $0.asNumber }
            return ns.isEmpty ? .null : .number(ns.min()!)
        case "max":
            let ns = args.compactMap { $0.asNumber }
            return ns.isEmpty ? .null : .number(ns.max()!)
        case "range":
            guard args.count >= 1 else { throw runtimeErr("range() expects at least 1 arg") }
            let a = Int(args[0].asNumber ?? 0)
            let b = args.count > 1 ? Int(args[1].asNumber ?? 0) : a
            let start = args.count > 1 ? a : 0
            return .range(start: start, end: b, inclusive: false)
        case "push":
            guard args.count == 2, case .array(let a) = args[0] else {
                throw runtimeErr("push(arr, x) expects array + value")
            }
            a.items.append(args[1])
            return .array(a)
        case "assert":
            if !(args.first ?? .null).isTruthy {
                let msg = args.count > 1 ? args[1].description : "assertion failed"
                throw runtimeErr(msg)
            }
            return .null
        case "error":
            throw runtimeErr(args.first?.description ?? "error")
        case "readLine":
            if let line = Swift.readLine() {
                return .string(line)
            }
            return .null
        case "time":
            return .number(Date().timeIntervalSince1970)
        case "sleep":
            let ms = args.first?.asNumber ?? 0
            Thread.sleep(forTimeInterval: ms / 1000.0)
            return .null
        case "json_parse":
            guard let a = args.first else { throw runtimeErr("json_parse expects 1 arg") }
            return try jsonParse(a)
        case "json_encode":
            guard let a = args.first else { throw runtimeErr("json_encode expects 1 arg") }
            return .string(try jsonEncode(a))
        default: return nil
        }
    }

    func callMethod(_ recv: Value, _ name: String, _ args: [Value], env: Env) throws -> Value {
        switch (recv, name) {
        case (.string(let s), "calc"):    return try calcString(s, env: env)
        case (.string(let s), "upper"):   return .string(s.uppercased())
        case (.string(let s), "lower"):   return .string(s.lowercased())
        case (.string(let s), "len"):     return .number(Double(s.count))
        case (.string(let s), "trim"):    return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case (.string(let s), "contains"):
            return .bool(s.contains(args.first?.description ?? ""))
        case (.string(let s), "startsWith"):
            return .bool(s.hasPrefix(args.first?.description ?? ""))
        case (.string(let s), "endsWith"):
            return .bool(s.hasSuffix(args.first?.description ?? ""))
        case (.string(let s), "replace"):
            guard args.count == 2 else { throw runtimeErr("replace(a, b) expects 2 args") }
            return .string(s.replacingOccurrences(of: args[0].description, with: args[1].description))
        case (.string(let s), "split"):
            let sep = args.first?.description ?? " "
            let parts = s.components(separatedBy: sep).map { Value.string($0) }
            return .array(ArrayRef(parts))
        case (.string(let s), "chars"):
            return .array(ArrayRef(s.map { .string(String($0)) }))
        case (.string(let s), "slice"):
            let chars = Array(s)
            let a = Int(args.first?.asNumber ?? 0)
            let b = args.count > 1 ? Int(args[1].asNumber ?? Double(chars.count)) : chars.count
            let lo = max(0, a < 0 ? chars.count + a : a)
            let hi = min(chars.count, b < 0 ? chars.count + b : b)
            return .string(String(chars[lo..<max(lo, hi)]))
        case (.number(let d), "abs"):   return .number(abs(d))
        case (.number(let d), "floor"): return .number(d.rounded(.down))
        case (.number(let d), "ceil"):  return .number(d.rounded(.up))
        case (.number(let d), "round"): return .number(d.rounded())
        case (.number(let d), "sqrt"):  return .number(d.squareRoot())
        case (.number(let d), "pow"):
            return .number(pow(d, args.first?.asNumber ?? 0))
        case (.array(let a), "len"):    return .number(Double(a.items.count))
        case (.array(let a), "push"):
            guard let v = args.first else { throw runtimeErr("push(x) expects 1 arg") }
            a.items.append(v)
            return .array(a)
        case (.array(let a), "pop"):
            guard let last = a.items.popLast() else {
                throw runtimeErr("pop() on empty array")
            }
            return last
        case (.array(let a), "contains"):
            return .bool(a.items.contains { valuesEqual($0, args.first ?? .null) })
        case (.array(let a), "reverse"):
            a.items.reverse()
            return .array(a)
        case (.array(let a), "sort"):
            a.items.sort { ($0.asNumber ?? 0) < ($1.asNumber ?? 0) }
            return .array(a)
        case (.array(let a), "slice"):
            let lo = Int(args.first?.asNumber ?? 0)
            let hi = args.count > 1 ? Int(args[1].asNumber ?? Double(a.items.count)) : a.items.count
            let L = max(0, lo < 0 ? a.items.count + lo : lo)
            let H = min(a.items.count, hi < 0 ? a.items.count + hi : hi)
            return .array(ArrayRef(Array(a.items[L..<max(L, H)])))
        case (.array(let a), "join"):
            let sep = args.first?.description ?? ""
            return .string(a.items.map { $0.description }.joined(separator: sep))
        case (.table(let t), "len"):    return .number(Double(t.entries.count))
        case (.table(let t), "keys"):
            return .array(ArrayRef(t.entries.map { $0.key }))
        case (.table(let t), "values"):
            return .array(ArrayRef(t.entries.map { $0.value }))
        case (.table(let t), "has"):
            return .bool(t.entries.contains { valuesEqual($0.key, args.first ?? .null) })
        case (.table(let t), "remove"):
            let k = args.first ?? .null
            if let i = t.entries.firstIndex(where: { valuesEqual($0.key, k) }) {
                let v = t.entries[i].value
                t.entries.remove(at: i)
                return v
            }
            return .null
        case (.table(let t), "merge"):
            guard args.count == 1, case .table(let o) = args[0] else {
                throw runtimeErr("merge(other) expects table")
            }
            for e in o.entries {
                if let i = t.entries.firstIndex(where: { valuesEqual($0.key, e.key) }) {
                    t.entries[i].value = e.value
                } else {
                    t.entries.append(e)
                }
            }
            return .table(t)
        case (.range(let s, let e, let inc), "len"):
            return .number(Double(max(0, inc ? (e - s + 1) : (e - s))))
        case (_, "toString"): return .string(recv.description)
        default:
            throw runtimeErr("unknown method '\(name)' on \(recv.typeName)")
        }
    }

    func jsonParse(_ v: Value) throws -> Value {
        guard case .string(let s) = v else {
            throw runtimeErr("json.parse expects string, got \(v.typeName)")
        }
        guard let data = s.data(using: .utf8) else {
            throw runtimeErr("json.parse: invalid utf8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw runtimeErr("json.parse: \(error.localizedDescription)")
        }
        return try anyToValue(parsed)
    }

    func anyToValue(_ any: Any) throws -> Value {
        switch any {
        case let n as NSNumber:
            let t = String(cString: n.objCType)
            if t == "c" || t == "B" {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            let ref = ArrayRef()
            for item in a { ref.items.append(try anyToValue(item)) }
            return .array(ref)
        case let d as [String: Any]:
            let ref = TableRef()
            for (k, v) in d { ref.entries.append((.string(k), try anyToValue(v))) }
            return .table(ref)
        case is NSNull:
            return .null
        default:
            throw runtimeErr("json.parse: unsupported type \(type(of: any))")
        }
    }

    func jsonEncode(_ v: Value) throws -> String {
        switch v {
        case .number(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null:        return "null"
        case .string(let s):
            var out = ""
            for c in s {
                switch c {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(c)
                }
            }
            return "\"" + out + "\""
        case .array(let a):
            let items = try a.items.map { try jsonEncode($0) }
            return "[" + items.joined(separator: ",") + "]"
        case .table(let t):
            var parts: [String] = []
            for (k, val) in t.entries {
                guard case .string(let key) = k else {
                    throw runtimeErr("json.encode: table keys must be strings")
                }
                parts.append("\"" + key + "\":" + (try jsonEncode(val)))
            }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            throw runtimeErr("json.encode: unsupported type \(v.typeName)")
        }
    }

    func calcString(_ s: String, env: Env) throws -> Value {
        let tokens = try Lexer(s).tokenize()
        let parser = Parser(tokens)
        let expr: Expr
        do { expr = try parser.parseExpression() }
        catch { return try calcFallback(s, env: env) }
        return try eval(expr, env: env)
    }

    func calcFallback(_ s: String, env: Env) throws -> Value {
        let tokens = try Lexer(s).tokenize()
        var nums: [Double] = []
        var op: String? = nil
        for t in tokens {
            switch t.kind {
            case .number(let d): nums.append(d)
            case .op(let o) where o != "(" && o != ")" && o != ",":
                if op == nil { op = o }
            case .string(let str):
                let trimmed = str.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let d = Double(trimmed) { nums.append(d) }
                else if op == nil { op = trimmed }
            default: break
            }
        }
        guard nums.count >= 2, let op = op else {
            throw runtimeErr("cannot calculate '\(s)'")
        }
        let a = nums[0], b = nums[1]
        switch op {
        case "+": return .number(a + b)
        case "-": return .number(a - b)
        case "*": return .number(a * b)
        case "/":
            if b == 0 { throw runtimeErr("division by zero") }
            return .number(a / b)
        case "%":
            if b == 0 { throw runtimeErr("modulo by zero") }
            return .number(a.truncatingRemainder(dividingBy: b))
        default: throw runtimeErr("unknown operator '\(op)'")
        }
    }

    func evalBinary(_ l: Expr, _ op: String, _ r: Expr, env: Env) throws -> Value {
        if op == "&&" {
            if !(try eval(l, env: env).isTruthy) { return .bool(false) }
            return .bool(try eval(r, env: env).isTruthy)
        }
        if op == "||" {
            if try eval(l, env: env).isTruthy { return .bool(true) }
            return .bool(try eval(r, env: env).isTruthy)
        }
        let lv = try eval(l, env: env), rv = try eval(r, env: env)
        switch op {
        case "+":
            if case .string = lv { return .string(lv.description + rv.description) }
            if case .string = rv { return .string(lv.description + rv.description) }
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("'+' expects numbers")
            }
            return .number(a + b)
        case "-":
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("'-' expects numbers")
            }
            return .number(a - b)
        case "*":
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("'*' expects numbers")
            }
            return .number(a * b)
        case "/":
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("'/' expects numbers")
            }
            if b == 0 { throw runtimeErr("division by zero") }
            return .number(a / b)
        case "%":
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("'%' expects numbers")
            }
            if b == 0 { throw runtimeErr("modulo by zero") }
            return .number(a.truncatingRemainder(dividingBy: b))
        case "..", "..=":
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("range expects numbers")
            }
            guard a.isFinite, b.isFinite else {
                throw runtimeErr("range bounds must be finite")
            }
            return .range(start: Int(a), end: Int(b), inclusive: op == "..=")
        case "in":
            switch rv {
            case .array(let a):
                return .bool(a.items.contains { valuesEqual($0, lv) })
            case .table(let t):
                return .bool(t.entries.contains { valuesEqual($0.key, lv) })
            case .string(let s):
                return .bool(s.contains(lv.description))
            case .range(let s, let e, let inc):
                if case .number(let n) = lv {
                    let ni = Int(n)
                    return .bool(inc ? (ni >= s && ni <= e) : (ni >= s && ni < e))
                }
                return .bool(false)
            default:
                throw runtimeErr("'in' not supported for \(rv.typeName)")
            }
        case "==": return .bool(valuesEqual(lv, rv))
        case "!=": return .bool(!valuesEqual(lv, rv))
        case "<", ">", "<=", ">=":
            guard let a = lv.asNumber, let b = rv.asNumber else {
                throw runtimeErr("comparison expects numbers")
            }
            switch op {
            case "<":  return .bool(a < b)
            case ">":  return .bool(a > b)
            case "<=": return .bool(a <= b)
            default:   return .bool(a >= b)
            }
        default: throw runtimeErr("unknown operator '\(op)'")
        }
    }

    func valuesEqual(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x),   .bool(let y)):   return x == y
        case (.null, .null):                   return true
        case (.range(let s1, let e1, let i1), .range(let s2, let e2, let i2)):
            return s1 == s2 && e1 == e2 && i1 == i2
        case (.array(let x), .array(let y)):
            guard x.items.count == y.items.count else { return false }
            for i in 0..<x.items.count {
                if !valuesEqual(x.items[i], y.items[i]) { return false }
            }
            return true
        default: return false
        }
    }
}

// ============ Entry point ============
func readSource() -> String {
    let args = CommandLine.arguments
    if args.count > 1 {
        let path = args[1]
        if path == "--version" {
            print("SimpleShit \(SIMPLESHIT_VERSION)")
            exit(0)
        }
        if path == "--help" || path == "-h" {
            print("""
            SimpleShit \(SIMPLESHIT_VERSION)

            Usage:
              simpleshit <file.ss>       run file
              simpleshit                 interactive REPL
              simpleshit --version       show version
              simpleshit --help          show this help
              echo '...' | simpleshit    run from stdin
            """)
            exit(0)
        }
        do { return try String(contentsOfFile: path, encoding: .utf8) }
        catch {
            FileHandle.standardError.write("cannot read \(path): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    var s = ""
    while let line = readLine(strippingNewline: false) { s += line }
    return s
}

let stdinIsTTY = isatty(STDIN_FILENO) != 0
let noFileArg  = CommandLine.arguments.count == 1

if stdinIsTTY && noFileArg {
    // -------- REPL --------
    print("SimpleShit \(SIMPLESHIT_VERSION) — REPL")
    print("Type 'quit' or Ctrl+D to exit.")
    let interp = Interpreter()
    while true {
        print("ss> ", terminator: "")
        guard let line = readLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == "quit" || trimmed == ":q" { break }
        do {
            let tokens = try Lexer(line).tokenize()
            let ast = try Parser(tokens).parse()
            try interp.run(ast)
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        }
    }
    exit(0)
} else {
    // -------- Script / pipe --------
    let source = readSource()
    do {
        let tokens = try Lexer(source).tokenize()
        let ast = try Parser(tokens).parse()
        try Interpreter().run(ast)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
