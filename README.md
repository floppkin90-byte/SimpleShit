SimpleShit

A tiny dynamically-typed scripting language implemented in a single Swift file.

SimpleShit 1.1.1 Stable — 363/363 tests passing in 0.09s, zero dependencies, ~1300 lines of Swift.
What it is

SimpleShit is a tree-walking interpreter written from scratch in one ss.swift file. It is built for learning how programming languages work — every layer (lexer, parser, AST, interpreter) is visible and readable in a single file.

It is not a production language. It is a complete, tested, working interpreter that you can read end-to-end in an evening.
Features

    Lexer with line/column tracking

    Recursive-descent parser with operator precedence

    AST-based tree-walking interpreter

    Closures with correct per-iteration capture

    Recursion, lexical scoping

    Tables (insertion-ordered) and arrays (reference semantics)

    Ranges: 0..5, 0..=5

    match with literals, lists, ranges, default

    Anonymous functions: fn(x) { return x * 2 }

    Destructuring: for k, v in table

    String interpolation: "hello %name%!"

    JSON: json.parse(...) / json.stringify(...)

    Runtime errors with line numbers

    REPL with persistent state

    Built-ins: readLine, time, sleep, len, str, num, int, type, abs, sqrt, floor, ceil, round, min, max, range, push, assert, error

    Zero dependencies (only Foundation)

Quick start
Pre-built binary (Linux x86_64)

Download simpleshit-1.1.1-linux-x86_64 from Releases.

chmod +x simpleshit-1.1.1-linux-x86_64
mv simpleshit-1.1.1-linux-x86_64 ~/.local/bin/simpleshit
simpleshit --version
From source

Requires Swift 5.9+ (swiftc in PATH).

git clone https://github.com/YOURNAME/simpleshit.git
cd simpleshit
swiftc -O ss.swift -o simpleshit
./simpleshit --version
Usage

simpleshit file.ss # run a script
simpleshit # interactive REPL
echo 'print 1+1' | simpleshit # read from stdin
simpleshit --version
simpleshit --help
Examples
Fibonacci

fn fib(n) {
if n < 2 { return n }
return fib(n - 1) + fib(n - 2)
}

for i in 0..=10 {
print "fib(%i%) =", fib(i)
}
JSON round-trip

data = json.parse("{"name":"Alice","age":30,"tags":["admin","dev"]}")
print "name:", data("name")
print "tags:", data("tags").join(", ")
print json.stringify(data)
Closures

fn make_adder(n) {
return fn(x) { return x + n }
}

add10 = make_adder(10)
print add10(5)
Match

fn describe(n) {
match n {
case 0 { return "zero" }
case 1, 2, 3 { return "small" }
case 4..10 { return "medium" }
default { return "large" }
}
}

print describe(0)
print describe(2)
print describe(7)
print describe(999)
Language at a glance
Comments: # or //

x = 10
name = "Ivan"
t = {"a": 1, "b": 2}
arr = [1, 2, 3]
r = 0..5

x += 1
t("a") += 5
arr(0) = 99

if x > 5 { print "big" }
elseif x > 0 { print "small" }
else { print "zero" }

while x > 0 { x -= 1 }

for i in 0..5 { print i }
for v in arr { print v }
for k, v in t { print "%k% = %v%" }

fn add(a, b) { return a + b }
double = fn(x) { return x * 2 }

s = "hello"
print s.upper(), s.len(), s.slice(1, 3)
print "1 + 2".calc()
Tests

The interpreter is covered by three test suites:
Suite	Checks	Purpose
tests/stabletest.ss	112	Contract: documented behavior
tests/monstertest.ss	171	Stress: recursion, closures, JSON, edge cases
tests/test.ss	80	Compact: one-liners for every feature

Total: 363 checks, full run in ~0.09s.

If you have the tests locally:

./simpleshit tests/stabletest.ss | tail -1
./simpleshit tests/monstertest.ss | tail -1
./simpleshit tests/test.ss | tail -1

Expected output:

STATUS: STABLE
MONSTERTEST PASSED
PASSED
Why "SimpleShit"?

Because every language starts as shit. This one just admits it.

The name is a joke. The code is not.
Status

    1.1.1 Stable — current. 363/363 tests. Closures, JSON, REPL, interpolation, line numbers, all features documented in tests.

    1.2 (planned) — BYTES type, try/catch, files (open/read/write), sockets.

    2.0 (planned) — real TCP via netstack.ss.

Non-goals

SimpleShit will never be:

    a production language

    faster than Python

    a replacement for Python in schools

    a general-purpose ecosystem

It exists to be read and understood, not to be deployed.
License

MIT — see LICENSE.
