//
//  Local.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Drop-in replacement for SwiftUI's @State. In recent SDKs @State is a macro
//  whose plugin ships only with full Xcode, so it can't compile with just the
//  Command Line Tools. @StateObject needs no macro, so we build on that.
//

import Combine
import SwiftUI

@propertyWrapper
struct Local<Value>: DynamicProperty {
	final class Box: ObservableObject {
		@Published var value: Value
		init(_ value: Value) { self.value = value }
	}

	@StateObject private var box: Box

	init(wrappedValue: Value) {
		_box = StateObject(wrappedValue: Box(wrappedValue))
	}

	var wrappedValue: Value {
		get { box.value }
		nonmutating set { box.value = newValue }
	}

	var projectedValue: Binding<Value> {
		Binding(get: { box.value }, set: { box.value = $0 })
	}
}
