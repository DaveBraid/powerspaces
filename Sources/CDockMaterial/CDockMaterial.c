// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only
#include "CDockMaterial.h"

// 编译器负责 Swift 寄存器约定；调用者负责先验证构建版本、符号及值类型布局。
#define SWIFT __attribute__((swiftcall))
#define RESULT __attribute__((swift_indirect_result))
#define CONTEXT __attribute__((swift_context))

typedef PSDockMetadata SWIFT MetadataFunction(uintptr_t);
typedef void SWIFT ConfigurationFunction(void * RESULT);
typedef void SWIFT ProviderFunction(void * RESULT, void *);
typedef void SWIFT MaterialFunction(void * RESULT, void *, const void *, const void *);
typedef void SWIFT SetActiveFunction(bool, void * CONTEXT);
typedef bool SWIFT GetActiveFunction(void * CONTEXT);

/// 取得完整元数据；请求 0 表示同步完成初始化。
PSDockMetadata PSDockGetMetadata(void *function) {
    return ((MetadataFunction *)function)(0);
}
/// 在未初始化存储中构造配方，结果通过 Swift 间接返回寄存器传递。
void PSDockMakeConfiguration(void *function, void *result) {
    ((ConfigurationFunction *)function)(result);
}
/// 初始化器消费 configuration；调用后只释放其存储，不再次析构。
void PSDockMakeProvider(void *function, void *result, void *configuration) {
    ((ProviderFunction *)function)(result, configuration);
}
/// 泛型初始化器消费 provider，元数据与协议见证表使用独立参数传递。
void PSDockMakeMaterial(void *function, void *result, void *provider, const void *metadata, const void *witness) {
    ((MaterialFunction *)function)(result, provider, metadata, witness);
}
/// 只写 SwiftUI 渲染环境；swift_context 传递可变 Self，不改变 AppKit 焦点。
void PSDockSetWindowActive(void *function, void *environment, bool active) {
    ((SetActiveFunction *)function)(active, environment);
}
/// 回读环境值，用于能力探测，不读取或修改实际窗口状态。
bool PSDockGetWindowActive(void *function, void *environment) {
    return ((GetActiveFunction *)function)(environment);
}
