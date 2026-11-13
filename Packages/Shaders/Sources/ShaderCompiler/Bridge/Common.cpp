// Bezzle's own: what the C face shares on every platform: strings handed to Swift, the lock that
// serialises calls into glslang and SPIRV-Cross, and checking which words a version takes.

#include "Bridge.h"
#include "ShaderCompiler.h"

#include <cstdlib>
#include <cstring>

namespace bezzle {

char *copyString(const std::string &text)
{
    char *result = static_cast<char *>(std::malloc(text.size() + 1));
    if (result != nullptr)
        std::memcpy(result, text.c_str(), text.size() + 1);
    return result;
}

std::mutex &translating()
{
    static std::mutex mutex;
    return mutex;
}

} // namespace bezzle

int bz_parses(const char *source, int stage, char **log)
{
    std::string messages;
    bool parsed;
    {
        std::lock_guard<std::mutex> lock(bezzle::translating());
        parsed = bezzle::parsesGLSL(source, stage == 1, messages);
    }
    if (log != nullptr)
        *log = bezzle::copyString(messages);
    return parsed ? 1 : 0;
}
