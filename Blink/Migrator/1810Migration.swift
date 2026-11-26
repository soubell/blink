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
////////////////////////////////////////////////////////////////////////////////


import Foundation
import CoreData


class MigrationFileProviderReplicatedExtension: MigrationStep {
  var version: Int { get { 1810 } }

  func execute() throws {
    // Replace old FileProvider extension items with the new FileProvider Replicated Extension
    for host in BKHosts.allHosts() {
      guard let json = host.fpDomainsJSON, !json.isEmpty
      else {
        continue
      }

      let domains = FileProviderDomain.listFrom(jsonString: json)
      if domains.count > 0 {
        domains.forEach { domain in
          if !domain.useReplicatedExtension {
            domain.useReplicatedExtension = true
          }
        }
        host.fpDomainsJSON = FileProviderDomain.toJson(list: domains)

        BKHosts._replaceHost(host)
      }
    }

    // Do we need it or does it happen on its own?
    BKiCloudSyncHandler.shared()?.check(forReachabilityAndSync: nil)

    // NOTE: The old File Provider storage used to be cleaned up here through
    // `NSFileProviderManager.default.documentStorageURL`. That property is only
    // valid inside the File Provider extension: calling it from the app raises
    // an NSInternalInconsistencyException, which is not catchable from Swift and
    // aborts the process during `didFinishLaunching`. The old extension no longer
    // exists and the system removes its container together with it, so there is
    // nothing to do here.
  }
}
