// Case-shim: libape sources #include <Windows.h> (uppercase); on case-
// sensitive filesystems that only resolves to THIS file. Use include_next
// to skip this shim and pull the real (lowercase) mingw <windows.h> from
// the rest of the include path, avoiding infinite self-recursion.
#include_next <windows.h>
