# Current architecture and bottlenecks

## Baseline implementation

Version 0.54 is a hybrid Perl + XS/C system.

- `pmat` and the companion scripts are Perl.
- Commands and tools are implemented mainly in Perl.
- `Devel::MAT::Dumpfile` parses the dump using repeated read/unpack logic.
- `MAT.xs` backs lower-level SV storage and accessors.
- Each analyzed SV is still exposed as a blessed Perl hash reference.

## Key performance issues

### 1. Eager per-SV Perl object construction
Every object in the heap becomes a Perl object plus a hash entry. That is expensive in memory and cache locality.

### 2. Repeated small parser reads
The parser performs many small Perl-level reads and unpack operations. That is slower than a buffered native parser.

### 3. Full heap rescans
Many commands scan the complete heap each time instead of using indices.

### 4. Quadratic hash traversal
Hash contents are stored in a native array. `value_at(key)` scans linearly, and the Perl hash outref traversal calls it for every key. That can produce O(K^2) behavior for large hashes.

### 5. First-use reverse-reference construction
Incoming-reference features build reverse edges lazily, which can create a very noticeable first-use pause.

### 6. Overbuilt top-K selection
`largest` uses a heavyweight heap structure to return only a few results.

## Architectural implication

Fixing the worst algorithms and using a dense native object model will deliver much more improvement than a pure language rewrite.
