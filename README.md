# zpeg

This is an Abstract Syntax Tree (AST) parser generator based on Parsing Expression Grammar (PEG). It can convert parsing expression grammar files into logically equivalent recursive descent parsing algorithms written in Zig.

During the conversion process, the logic is checked, and if the parsing logic would cause the parser to enter an infinite recursion or infinite loop state, an error will be reported, and indicating the logical location that causes the error.
