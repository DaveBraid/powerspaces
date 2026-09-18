// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

// macOS 27 SDK 同时声明了 State 宏；显式别名继续使用原有属性包装器，兼容仅装 CLT 的构建。
typealias ViewState<Value> = SwiftUI.State<Value>
