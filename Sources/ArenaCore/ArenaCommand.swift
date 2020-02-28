//
//  ArenaCommand.swift
//  
//
//  Created by Sven A. Schmidt on 23/12/2019.
//

import ArgumentParser
import Foundation
import Path
import ShellOut


public enum ArenaError: LocalizedError {
    case missingDependency
    case pathExists(String)
    case noLibrariesFound

    public var errorDescription: String? {
        switch self {
            case .missingDependency:
                return "provide at least one dependency via the -d parameter"
            case .pathExists(let path):
                return "'\(path)' already exists, use '-f' to overwrite"
            case .noLibrariesFound:
                return "no libraries found, make sure the referenced dependencies define library products"
        }
    }
}


public struct Arena: ParsableCommand {
    public init() {}

    public static var configuration = CommandConfiguration(
        abstract: "Creates an Xcode project with a Playground and one or more SPM libraries imported and ready for use."
    )

    @Option(name: [.customLong("name"), .customShort("n")], default: "SPM-Playground", help: "Name of directory and Xcode project")
    var projectName: String

    @Option(name: [.customLong("deps"), .customShort("d")], help: "Dependency url(s) and (optionally) version specification")
    var dependencies: [Dependency]

    @Option(name: [.customLong("libs"), .customShort("l")], help: "Names of libraries to import (inferred if not provided)")
    var libNames: [String]

    @Option(name: .shortAndLong, default: .macos, help: "Platform for Playground (one of 'macos', 'ios', 'tvos')")
    var platform: Platform

    @Option(name: .shortAndLong, default: false, help: "Overwrite existing file/directory")
    var force: Bool

    @Option(name: [.customLong("outputdir"), .customShort("o")], default: Path.cwd, help: "Directory where project folder should be saved")
    var outputPath: Path

    @Option(name: .shortAndLong, default: false, help: "Show version")
    var version: Bool

    var targetName: String { projectName }

    var projectPath: Path { outputPath/projectName }

    var xcodeprojPath: Path {
        projectPath/"\(projectName).xcodeproj"
    }

    var xcworkspacePath: Path {
        projectPath/"\(projectName).xcworkspace"
    }

    var playgroundPath: Path {
        projectPath/"MyPlayground.playground"
    }

    public func run() throws {
        guard !dependencies.isEmpty else {
            throw ArenaError.missingDependency
        }

        if force && projectPath.exists {
            try projectPath.delete()
        }
        guard !projectPath.exists else {
            throw ArenaError.pathExists(projectPath.basename())
        }

        // create package
        do {
            try projectPath.mkdir()
            try shellOut(to: .createSwiftPackage(withType: .library), at: projectPath)
        }

        // update Package.swift dependencies
        do {
            let packagePath = projectPath/"Package.swift"
            let packageDescription = try String(contentsOf: packagePath)
            let depsClause = dependencies.map { "    " + $0.packageClause }.joined(separator: ",\n")
            let updatedDeps = "package.dependencies = [\n\(depsClause)\n]"
            try [packageDescription, updatedDeps].joined(separator: "\n").write(to: packagePath)
        }

        do {
            print("🔧  resolving package dependencies")
            try shellOut(to: ShellOutCommand(string: "swift package resolve"), at: projectPath)
        }

        let libs: [LibraryInfo]
        do {
            // find libraries
            libs = try dependencies
                .compactMap { $0.path ?? $0.checkoutDir(projectDir: projectPath) }
                .flatMap { try getLibraryInfo(for: $0) }
            if libs.isEmpty { throw ArenaError.noLibrariesFound }
            print("📔  libraries found: \(libs.map({ $0.libraryName }).joined(separator: ", "))")
        }

        // update Package.swift targets
        do {
            let packagePath = projectPath/"Package.swift"
            let packageDescription = try String(contentsOf: packagePath)
            let productsClause = libs.map {
                """
                .product(name: "\($0.libraryName)", package: "\($0.packageName)")
                """
            }.joined(separator: ",\n")
            let updatedTgts =  """
                package.targets = [
                    .target(name: "\(targetName)",
                        dependencies: [
                            \(productsClause)
                        ]
                    )
                ]
                """
            try [packageDescription, updatedTgts].joined(separator: "\n").write(to: packagePath)
        }

        // generate xcodeproj
        try shellOut(to: .generateSwiftPackageXcodeProject(), at: projectPath)

        // create workspace
        do {
            try xcworkspacePath.mkdir()
            try """
                <?xml version="1.0" encoding="UTF-8"?>
                <Workspace
                version = "1.0">
                <FileRef
                location = "group:MyPlayground.playground">
                </FileRef>
                <FileRef
                location = "container:\(xcodeprojPath.basename())">
                </FileRef>
                </Workspace>
                """.write(to: xcworkspacePath/"contents.xcworkspacedata")
        }

        // add playground
        do {
            try playgroundPath.mkdir()
            let libsToImport = !libNames.isEmpty ? libNames : libs.map({ $0.libraryName })
            let importClauses = libsToImport.map { "import \($0)" }.joined(separator: "\n") + "\n"
            try importClauses.write(to: playgroundPath/"Contents.swift")
            try """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <playground version='5.0' target-platform='\(platform)'>
                <timeline fileName='timeline.xctimeline'/>
                </playground>
                """.write(to: playgroundPath/"contents.xcplayground")
        }

        print("✅  created project in folder '\(projectPath.relative(to: Path.cwd))'")
        try shellOut(to: .openFile(at: xcworkspacePath))
    }
}
