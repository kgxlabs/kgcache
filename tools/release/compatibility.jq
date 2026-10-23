# Conventional Commit declarations are a guard. Review still judges compatibility.
def maintenance_compatible:
  (test("\\Afeat(?:\\([^()\\r\\n]+\\))?!?:[ \\t]+"; "i") or
   test("\\A[A-Za-z0-9_]+(?:\\([^()\\r\\n]+\\))?!:") or
   test("(^|\\n)BREAKING[ -]CHANGE:[ \\t]*"; "i")) | not;

if maintenance_compatible then true
else error("maintenance changes must not declare features or breaking changes") end
