// Generates deterministic fixtures using the unmodified Meta C++ reference.
// Compile instructions and pinned source revision are in README.md.
#include <pdq/cpp/hashing/pdqhashing.h>

#include <cstdio>
#include <cstdint>
#include <vector>

using namespace facebook::pdq::hashing;

int main() {
  const int dimensions[][2] = {
      {4, 8}, {8, 4}, {5, 5}, {17, 29}, {63, 65}, {64, 64},
      {65, 64}, {128, 128}, {129, 257}, {256, 193}, {513, 391}};
  std::printf("[\n");
  bool first = true;
  for (const auto& d : dimensions) {
    for (int mode = 0; mode < 4; mode++) {
      const int width = d[0], height = d[1];
      const int channels = mode == 0 ? 1 : 3;
      std::vector<uint8_t> pixels(width * height * channels);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          for (int c = 0; c < channels; c++) {
            int value;
            if (mode == 2) {
              value = 127;
            } else if (mode == 3) {
              value = ((x / 3 + y / 5) % 2) * 255;
            } else {
              value = (x * 17 + y * 31 + x * y * 7 +
                       c * 53 + c * x * 11 + c * y * 3) & 255;
            }
            pixels[(y * width + x) * channels + c] = value;
          }
        }
      }
      std::vector<float> luma(width * height), scratch(width * height);
      if (channels == 1) {
        fillFloatLumaFromGrey(pixels.data(), height, width, width, 1, luma.data());
      } else {
        fillFloatLumaFromRGB(pixels.data(), pixels.data() + 1, pixels.data() + 2,
                            height, width, width * 3, 3, luma.data());
      }
      float small[64][64], intermediate[16][64], coefficients[16][16];
      Hash256 hash;
      int quality;
      pdqHash256FromFloatLuma(luma.data(), scratch.data(), height, width,
                             small, intermediate, coefficients, hash, quality);
      if (!first) std::printf(",\n");
      first = false;
      std::printf("  {\"width\":%d,\"height\":%d,\"mode\":%d,\"quality\":%d,\"hash\":\"",
                  width, height, mode, quality);
      for (int word = 15; word >= 0; word--) {
        std::printf("%04x", static_cast<unsigned>(hash.w[word]));
      }
      std::printf("\"}");
    }
  }
  std::printf("\n]\n");
}
