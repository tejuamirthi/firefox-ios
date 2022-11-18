// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Shared
import SwiftyJSON

private let log = Logger.syncLogger

open class SQLiteRemoteClientsAndTabs: RemoteClientsAndTabs {
    let db: BrowserDB

    public init(db: BrowserDB) {
        self.db = db
    }

    class func remoteClientFactory(_ row: SDRow) -> RemoteClient {
        let guid = row["guid"] as? String
        let name = row["name"] as! String
        let mod = (row["modified"] as! NSNumber).uint64Value
        let type = row["type"] as? String
        let form = row["formfactor"] as? String
        let os = row["os"] as? String
        let version = row["version"] as? String
        let fxaDeviceId = row["fxaDeviceId"] as? String
        return RemoteClient(guid: guid, name: name, modified: mod, type: type, formfactor: form, os: os, version: version, fxaDeviceId: fxaDeviceId)
    }

    class func remoteDeviceFactory(_ row: SDRow) -> RemoteDevice {
        let availableCommands = JSON(parseJSON: (row["availableCommands"] as? String) ?? "{}")
        return RemoteDevice(
            id: row["guid"] as? String,
            name: row["name"] as! String,
            type: row["type"] as? String,
            isCurrentDevice: row["is_current_device"] as! Int > 0,
            lastAccessTime: row["last_access_time"] as? Timestamp,
            availableCommands: availableCommands)
    }

    class func convertStringToHistory(_ history: String?) -> [URL] {
        guard let data = history?.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data, options: [JSONSerialization.ReadingOptions.allowFragments]),
            let urlStrings = decoded as? [String] else {
                return []
        }
        return optFilter(urlStrings.compactMap { URL(string: $0) })
    }

    class func convertHistoryToString(_ history: [URL]) -> String? {
        let historyAsStrings = optFilter(history.map { $0.absoluteString })

        guard let data = try? JSONSerialization.data(withJSONObject: historyAsStrings, options: []) else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: String.Encoding.utf8.rawValue))
    }

    open func wipeClients() -> Success {
        return db.run("DELETE FROM clients")
    }

    open func insertOrUpdateClients(_ clients: [RemoteClient]) -> Deferred<Maybe<Int>> {
        // TODO: insert multiple clients in a single query.
        // ORM systems are foolish.
        return db.transaction { connection -> Int in
            var succeeded = 0

            // Update or insert client records.
            for client in clients {
                let args: Args = [
                    client.name,
                    NSNumber(value: client.modified),
                    client.type,
                    client.formfactor,
                    client.os,
                    client.version,
                    client.fxaDeviceId,
                    client.guid
                ]

                try connection.executeChange("UPDATE clients SET name = ?, modified = ?, type = ?, formfactor = ?, os = ?, version = ?, fxaDeviceId = ? WHERE guid = ?", withArgs: args)

                if connection.numberOfRowsModified == 0 {
                    let args: Args = [
                        client.guid,
                        client.name,
                        NSNumber(value: client.modified),
                        client.type,
                        client.formfactor,
                        client.os,
                        client.version,
                        client.fxaDeviceId
                    ]

                    let lastInsertedRowID = connection.lastInsertedRowID

                    try connection.executeChange("INSERT INTO clients (guid, name, modified, type, formfactor, os, version, fxaDeviceId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", withArgs: args)

                    if connection.lastInsertedRowID == lastInsertedRowID {
                        log.debug("INSERT did not change last inserted row ID.")
                    }
                }

                succeeded += 1
            }

            return succeeded
        }
    }

    open func insertOrUpdateClient(_ client: RemoteClient) -> Deferred<Maybe<Int>> {
        return insertOrUpdateClients([client])
    }

    open func deleteClient(guid: GUID) -> Success {
        let deleteTabsQuery = "DELETE FROM tabs WHERE client_guid = ?"
        let deleteClientQuery = "DELETE FROM clients WHERE guid = ?"
        let deleteArgs: Args = [guid]

        return db.transaction { connection -> Void in
            try connection.executeChange(deleteClientQuery, withArgs: deleteArgs)
            try connection.executeChange(deleteTabsQuery, withArgs: deleteArgs)
        }
    }

    open func getClient(guid: GUID) -> Deferred<Maybe<RemoteClient?>> {
        let factory = SQLiteRemoteClientsAndTabs.remoteClientFactory
        return self.db.runQuery("SELECT * FROM clients WHERE guid = ?", args: [guid], factory: factory) >>== { deferMaybe($0[0]) }
    }

    open func getClient(fxaDeviceId: String) -> Deferred<Maybe<RemoteClient?>> {
        let factory = SQLiteRemoteClientsAndTabs.remoteClientFactory
        return self.db.runQuery("SELECT * FROM clients WHERE fxaDeviceId = ?", args: [fxaDeviceId], factory: factory) >>== { deferMaybe($0[0]) }
    }

    open func getClients() -> Deferred<Maybe<[RemoteClient]>> {
        return db.withConnection { connection -> [RemoteClient] in
            let cursor = connection.executeQuery(
                "SELECT * FROM clients WHERE EXISTS (SELECT 1 FROM remote_devices rd WHERE rd.guid = fxaDeviceId) ORDER BY modified DESC",
                factory: SQLiteRemoteClientsAndTabs.remoteClientFactory)
            defer {
                cursor.close()
            }

            return cursor.asArray()
        }
    }

    open func getClientGUIDs() -> Deferred<Maybe<Set<GUID>>> {
        let c = db.runQuery("SELECT guid FROM clients WHERE guid IS NOT NULL", args: nil, factory: { $0["guid"] as! String })
        return c >>== { cursor in
            let guids = Set<GUID>(cursor.asArray())
            return deferMaybe(guids)
        }
    }

    open func deleteCommands() -> Success {
        return db.run("DELETE FROM commands")
    }

    open func deleteCommands(_ clientGUID: GUID) -> Success {
        return db.run("DELETE FROM commands WHERE client_guid = ?", withArgs: [clientGUID] as Args)
    }

    open func insertCommand(_ command: SyncCommand, forClients clients: [RemoteClient]) -> Deferred<Maybe<Int>> {
        return insertCommands([command], forClients: clients)
    }

    open func insertCommands(_ commands: [SyncCommand], forClients clients: [RemoteClient]) -> Deferred<Maybe<Int>> {
        return db.transaction { connection -> Int in
            var numberOfInserts = 0

            // Update or insert client records.
            for command in commands {
                for client in clients {
                    do {
                        if let commandID = try self.insert(connection, sql: "INSERT INTO commands (client_guid, value) VALUES (?, ?)", args: [client.guid, command.value] as Args) {
                            log.verbose("Inserted command: \(commandID)")
                            numberOfInserts += 1
                        } else {
                            log.warning("Command not inserted, but no error!")
                        }
                    } catch let err as NSError {
                        log.error("insertCommands(_:, forClients:) failed: \(err.localizedDescription) (numberOfInserts: \(numberOfInserts)")
                        throw err
                    }
                }
            }

            return numberOfInserts
        }
    }

    open func getCommands() -> Deferred<Maybe<[GUID: [SyncCommand]]>> {
        return db.withConnection { connection -> [GUID: [SyncCommand]] in
            let cursor = connection.executeQuery("SELECT * FROM commands", factory: { row -> SyncCommand in
                SyncCommand(
                    id: row["command_id"] as? Int,
                    value: row["value"] as! String,
                    clientGUID: row["client_guid"] as? GUID)
            })
            defer {
                cursor.close()
            }

            return self.clientsFromCommands(cursor.asArray())
        }
    }

    func clientsFromCommands(_ commands: [SyncCommand]) -> [GUID: [SyncCommand]] {
        var syncCommands = [GUID: [SyncCommand]]()
        for command in commands {
            var cmds: [SyncCommand] = syncCommands[command.clientGUID!] ?? [SyncCommand]()
            cmds.append(command)
            syncCommands[command.clientGUID!] = cmds
        }
        return syncCommands
    }

    func insert(_ db: SQLiteDBConnection, sql: String, args: Args?) throws -> Int64? {
        let lastID = db.lastInsertedRowID
        try db.executeChange(sql, withArgs: args)

        let id = db.lastInsertedRowID
        if id == lastID {
            log.debug("INSERT did not change last inserted row ID.")
            return nil
        }

        return id
    }
}

extension SQLiteRemoteClientsAndTabs: RemoteDevices {
    public func replaceRemoteDevices(_ remoteDevices: [RemoteDevice]) -> Success {
        // Drop corrupted records and our own record too.
        let remoteDevices = remoteDevices.filter { $0.id != nil && $0.type != nil && !$0.isCurrentDevice }

        return db.transaction { conn -> Void in
            try conn.executeChange("DELETE FROM remote_devices")

            let now = Date.now()

            for device in remoteDevices {
                let sql = """
                    INSERT INTO remote_devices (
                        guid, name, type, is_current_device, date_created, date_modified, last_access_time, availableCommands
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """

                let availableCommands = device.availableCommands?.rawString(options: []) ?? "{}"
                let args: Args = [device.id, device.name, device.type, device.isCurrentDevice, now, now, device.lastAccessTime, availableCommands]
                try conn.executeChange(sql, withArgs: args)
            }
        }
    }
}

extension SQLiteRemoteClientsAndTabs: ResettableSyncStorage {
    public func resetClient() -> Success {
        // For this engine, resetting is equivalent to wiping.
        return self.clear()
    }

    public func clear() -> Success {
        return db.transaction { conn -> Void in
            try conn.executeChange("DELETE FROM tabs WHERE client_guid IS NOT NULL")
            try conn.executeChange("DELETE FROM clients")
        }
    }
}

extension SQLiteRemoteClientsAndTabs: AccountRemovalDelegate {
    public func onRemovedAccount() -> Success {
        log.info("Clearing clients and tabs after account removal.")
        // TODO: Bug 1168690 - delete our client and tabs records from the server.
        return self.resetClient()
    }
}
