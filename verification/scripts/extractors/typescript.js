#!/usr/bin/env node
/**
 * Extract exported types from TypeScript files using the TypeScript compiler API.
 *
 * Usage: node extract-ts-types.js <file-or-directory> [--json]
 *
 * Outputs one type per line, or JSON if --json flag is provided.
 *
 * Example:
 *   node extract-ts-types.js ./packages/core/src/types/types.ts
 *   node extract-ts-types.js ./packages --json
 */

const ts = require('typescript');
const fs = require('fs');
const path = require('path');

function extractTypesFromFile(filePath) {
    const types = [];

    if (!fs.existsSync(filePath)) {
        console.error(`File not found: ${filePath}`);
        return types;
    }

    const content = fs.readFileSync(filePath, 'utf-8');
    const sourceFile = ts.createSourceFile(
        filePath,
        content,
        ts.ScriptTarget.Latest,
        true
    );

    function visit(node) {
        // Check if node is exported
        const isExported = node.modifiers?.some(
            mod => mod.kind === ts.SyntaxKind.ExportKeyword
        );

        if (isExported) {
            if (ts.isInterfaceDeclaration(node)) {
                types.push({
                    name: node.name.text,
                    kind: 'interface',
                    file: filePath,
                    line: sourceFile.getLineAndCharacterOfPosition(node.getStart()).line + 1
                });
            } else if (ts.isTypeAliasDeclaration(node)) {
                types.push({
                    name: node.name.text,
                    kind: 'type',
                    file: filePath,
                    line: sourceFile.getLineAndCharacterOfPosition(node.getStart()).line + 1
                });
            } else if (ts.isEnumDeclaration(node)) {
                types.push({
                    name: node.name.text,
                    kind: 'enum',
                    file: filePath,
                    line: sourceFile.getLineAndCharacterOfPosition(node.getStart()).line + 1
                });
            } else if (ts.isClassDeclaration(node) && node.name) {
                types.push({
                    name: node.name.text,
                    kind: 'class',
                    file: filePath,
                    line: sourceFile.getLineAndCharacterOfPosition(node.getStart()).line + 1
                });
            } else if (ts.isVariableStatement(node)) {
                // Handle exported constants
                for (const decl of node.declarationList.declarations) {
                    if (ts.isIdentifier(decl.name)) {
                        types.push({
                            name: decl.name.text,
                            kind: 'const',
                            file: filePath,
                            line: sourceFile.getLineAndCharacterOfPosition(node.getStart()).line + 1
                        });
                    }
                }
            }
        }

        ts.forEachChild(node, visit);
    }

    visit(sourceFile);
    return types;
}

function extractTypesFromDirectory(dirPath, pattern = /\.ts$/) {
    const types = [];

    function walkDir(dir) {
        if (!fs.existsSync(dir)) return;

        const entries = fs.readdirSync(dir, { withFileTypes: true });
        for (const entry of entries) {
            const fullPath = path.join(dir, entry.name);
            if (entry.isDirectory()) {
                // Skip node_modules and hidden directories
                if (entry.name !== 'node_modules' && !entry.name.startsWith('.')) {
                    walkDir(fullPath);
                }
            } else if (entry.isFile() && pattern.test(entry.name)) {
                types.push(...extractTypesFromFile(fullPath));
            }
        }
    }

    walkDir(dirPath);
    return types;
}

function checkTypeExists(filePath, typeName) {
    const types = extractTypesFromFile(filePath);
    const found = types.find(t => t.name === typeName);
    return found ? { exists: true, ...found } : { exists: false, name: typeName };
}

// CLI interface
if (require.main === module) {
    const args = process.argv.slice(2);
    const jsonOutput = args.includes('--json');
    const checkMode = args.includes('--check');
    const targetPath = args.find(a => !a.startsWith('--'));

    if (!targetPath) {
        console.error('Usage: extract-ts-types.js <file-or-directory> [--json] [--check <type-name>]');
        process.exit(1);
    }

    if (checkMode) {
        const typeName = args[args.indexOf('--check') + 1];
        if (!typeName) {
            console.error('--check requires a type name');
            process.exit(1);
        }
        const result = checkTypeExists(targetPath, typeName);
        if (jsonOutput) {
            console.log(JSON.stringify(result));
        } else {
            console.log(result.exists ? `Found: ${result.name} (${result.kind})` : `Not found: ${typeName}`);
        }
        process.exit(result.exists ? 0 : 1);
    }

    const stat = fs.statSync(targetPath);
    const types = stat.isDirectory()
        ? extractTypesFromDirectory(targetPath)
        : extractTypesFromFile(targetPath);

    if (jsonOutput) {
        console.log(JSON.stringify(types, null, 2));
    } else {
        // Output one type per line: name:kind:file:line
        for (const t of types) {
            console.log(`${t.name}:${t.kind}:${t.file}:${t.line}`);
        }
    }
}

module.exports = { extractTypesFromFile, extractTypesFromDirectory, checkTypeExists };
