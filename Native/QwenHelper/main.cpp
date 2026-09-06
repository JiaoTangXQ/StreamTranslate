// Serialized, private stdio worker. No HTTP listener, shell, or Python runtime.
#include "qwen3_asr.h"
#include <chrono>
#include <iostream>
#include <string>

static double seconds(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

static std::string single_line(std::string value) {
    for (char &c : value) if (c == '\n' || c == '\r' || c == '\t') c = ' ';
    return value;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    qwen3_asr::Qwen3ASR model;
    const auto start = std::chrono::steady_clock::now();
    if (!model.load_model(argv[1])) {
        std::cout << "ERROR\t" << single_line(model.get_error()) << std::endl;
        return 1;
    }
    std::cout << "READY\t" << seconds(start) << std::endl;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line == "QUIT") break;
        const auto separator = line.find('\t');
        if (line.size() > 8192 || separator == std::string::npos) return 2;
        const auto id = line.substr(0, separator);
        const auto path = line.substr(separator + 1);
        qwen3_asr::transcribe_params params;
        params.max_tokens = 256;
        params.n_threads = 4;
        params.print_timing = false;
        const auto began = std::chrono::steady_clock::now();
        const auto result = model.transcribe(path, params);
        const bool complete = result.success && result.tokens.size() < static_cast<size_t>(params.max_tokens);
        std::cout << id << '\t' << (complete ? "OK" : "ERROR")
                  << '\t' << seconds(began) << '\t'
                  << single_line(complete ? result.text : (result.success ? "token limit reached" : result.error_msg))
                  << std::endl;
    }
}
