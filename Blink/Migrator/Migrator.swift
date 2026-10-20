//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2024 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
//////////////////////////////////////////////////////////////////////////////////


import Foundation
import BlinkConfig


@objc class Migrator : NSObject {
  @objc static func perform() {
    Self.perform(steps: [MigrationToAppGroup(),
                         MigrationAddSnippetsShortcut(),
                         MigrationFileProviderReplicatedExtension(),
                         MigrationStyleFromDefaults()
                        ])
  }

  static func perform(steps: [MigrationStep]) {
    // BlinkPaths falls back to the app container when the App Group is missing
    // (sideloaded / re-signed builds), but never trap here if it cannot resolve
    // a path at all: the app would crash on launch before showing anything.
    guard let containerPath = BlinkPaths.groupContainerPath(), !containerPath.isEmpty else {
      NSLog("[Migrator] Could not resolve a container path. Skipping migrations.")
      return
    }

    let migratorFileURL = URL(fileURLWithPath: containerPath).appendingPathComponent(".migrator")

    let currentVersionString = try? String(contentsOf: migratorFileURL, encoding: .utf8)
    var currentVersion = Int(currentVersionString ?? "0") ?? 0

    for step in steps.sorted(by: { $0.version < $1.version }) {
      guard step.version > currentVersion else {
        continue
      }

      // Swift's do/catch does not handle Objective-C exceptions. Apple
      // frameworks raise them for APIs that are used outside of their
      // supported context, and an uncaught one aborts the app. A migration
      // must never keep Blink from launching, so both kinds of failure are
      // contained here.
      var stepError: Error? = nil
      let completed = BKExceptionCatcher.performSafely {
        do {
          try step.execute()
        } catch {
          stepError = error
        }
      }

      if let error = stepError {
        NSLog("[Migrator] Migration step \(step.version) failed: \(error). Will retry on next launch.")
        break
      }

      if !completed {
        let reason = BKExceptionCatcher.lastExceptionDescription() ?? "unknown"
        NSLog("[Migrator] Migration step \(step.version) raised an exception: \(reason). Will retry on next launch.")
        break
      }

      currentVersion = step.version

      guard let data = String(currentVersion).data(using: .utf8) else {
        NSLog("[Migrator] Could not encode migration version \(currentVersion).")
        break
      }

      do {
        try data.write(to: migratorFileURL, options: [.atomic, .noFileProtection])
      } catch {
        NSLog("[Migrator] Could not persist migration version \(currentVersion): \(error).")
        break
      }
    }
  }
}

protocol MigrationStep {
  // Migration steps should be idempotent
  func execute() throws
  // After a step is applied, the version is updated
  var version: Int { get }
}
