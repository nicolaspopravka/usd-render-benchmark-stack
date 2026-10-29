#include <pxr/usd/usd/stage.h>
#include <iostream>

int main() {
    auto stage = pxr::UsdStage::CreateInMemory();
    if (!stage) return 1;
    std::cout << "CONSUMER_PASS\n";
    return 0;
}
