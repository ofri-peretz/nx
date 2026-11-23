import {
  readProjectConfiguration,
  visitNotIgnoredFiles,
  type Tree,
} from '@nx/devkit';
import { insertImport } from '@nx/js';
import {
  ast,
  ensureTypescript,
  printNodeUpdate,
  query,
  type TypescriptAst,
} from '@nx/devkit/internal';
import type {
  CallExpression,
  ImportSpecifier,
  ObjectLiteralElementLike,
  ObjectLiteralExpression,
  SourceFile,
} from 'typescript';
import type { NormalizedGeneratorOptions } from '../schema';

let ts: TypescriptAst;

export function setRouterInitialNavigation(
  tree: Tree,
  options: NormalizedGeneratorOptions
): void {
  ts ??= ensureTypescript();
  const project = readProjectConfiguration(tree, options.project);

  visitNotIgnoredFiles(tree, project.root, (filePath) => {
    // we are only interested in .ts files
    if (!filePath.endsWith('.ts')) {
      return;
    }

    if (options.standalone) {
      processFileWithStandaloneSetup(tree, filePath);
    } else {
      processFileWithNgModuleSetup(tree, filePath);
    }
  });
}

function processFileWithStandaloneSetup(tree: Tree, filePath: string) {
  let content = tree.read(filePath, 'utf-8');
  let sourceFile = ast(content);

  const provideRouterCallExpression =
    getProvideRouterCallExpression(sourceFile);
  if (!provideRouterCallExpression) {
    return;
  }

  if (
    provideRouterCallExpression.arguments.some(
      (arg) =>
        ts.isCallExpression(arg) &&
        ts.isIdentifier(arg.expression) &&
        arg.expression.text === 'withEnabledBlockingInitialNavigation'
    )
  ) {
    return;
  }

  const updatedProvideRouterCallExpression = printNodeUpdate(
    provideRouterCallExpression,
    updateProvideRouterCallExpression(provideRouterCallExpression)
  );

  content = `${content.slice(
    0,
    provideRouterCallExpression.getStart()
  )}${updatedProvideRouterCallExpression}${content.slice(
    provideRouterCallExpression.getEnd()
  )}`;

  tree.write(filePath, content);

  sourceFile = ast(content);
  sourceFile = insertImport(
    tree,
    sourceFile,
    filePath,
    'withEnabledBlockingInitialNavigation',
    '@angular/router'
  );

  const withDisabledInitialNavigationImportNode = query(
    sourceFile,
    'ImportDeclaration ImportSpecifier:has(Identifier[name=withDisabledInitialNavigation])'
  )[0] as ImportSpecifier;
  if (!withDisabledInitialNavigationImportNode) {
    return;
  }

  const hasTrailingComma =
    withDisabledInitialNavigationImportNode.parent.elements.hasTrailingComma;

  content = tree.read(filePath, 'utf-8');
  tree.write(
    filePath,
    `${content.slice(
      0,
      withDisabledInitialNavigationImportNode.getStart()
    )}${content.slice(
      withDisabledInitialNavigationImportNode.getEnd() +
        (hasTrailingComma ? 1 : 0)
    )}`
  );
}

function updateProvideRouterCallExpression(
  node: CallExpression
): CallExpression {
  const filteredArgs = node.arguments.filter(
    (arg) =>
      !(
        ts.isCallExpression(arg) &&
        ts.isIdentifier(arg.expression) &&
        arg.expression.text === 'withDisabledInitialNavigation'
      )
  );

  const initialNavigationFeatureArg = ts.factory.createCallExpression(
    ts.factory.createIdentifier('withEnabledBlockingInitialNavigation'),
    [],
    []
  );

  return ts.factory.updateCallExpression(
    node,
    node.expression,
    node.typeArguments,
    [...filteredArgs, initialNavigationFeatureArg]
  );
}

function processFileWithNgModuleSetup(tree: Tree, filePath: string) {
  const content = tree.read(filePath, 'utf-8');
  const sourceFile = ast(content);

  const routerModuleForRootCallExpression =
    getRouterModuleForRootCallExpression(sourceFile);
  if (!routerModuleForRootCallExpression) {
    return;
  }

  const updatedRouterModuleForRootCallExpression = printNodeUpdate(
    routerModuleForRootCallExpression,
    updateRouterModuleForRootCallExpression(routerModuleForRootCallExpression)
  );

  tree.write(
    filePath,
    `${content.slice(
      0,
      routerModuleForRootCallExpression.getStart()
    )}${updatedRouterModuleForRootCallExpression}${content.slice(
      routerModuleForRootCallExpression.getEnd()
    )}`
  );
}

function updateRouterModuleForRootCallExpression(
  node: CallExpression
): CallExpression {
  const existingOptions = node.arguments[1] as
    | ObjectLiteralExpression
    | undefined;

  const existingProperties = existingOptions?.properties
    ? ts.factory.createNodeArray(
        existingOptions.properties.filter(
          (exp) =>
            !(
              ts.isPropertyAssignment(exp) &&
              ts.isIdentifier(exp.name) &&
              exp.name.text === 'initialNavigation'
            )
        )
      )
    : ts.factory.createNodeArray<ObjectLiteralElementLike>();

  const enabledLiteral = ts.factory.createStringLiteral(
    'enabledBlocking',
    true
  );
  const initialNavigationProperty = ts.factory.createPropertyAssignment(
    'initialNavigation',
    enabledLiteral
  );

  const routerOptions = existingOptions
    ? ts.factory.updateObjectLiteralExpression(
        existingOptions,
        ts.factory.createNodeArray([
          ...existingProperties,
          initialNavigationProperty,
        ])
      )
    : ts.factory.createObjectLiteralExpression(
        ts.factory.createNodeArray([initialNavigationProperty])
      );
  const args = [node.arguments[0], routerOptions];

  return ts.factory.updateCallExpression(
    node,
    node.expression,
    node.typeArguments,
    args
  );
}

function getProvideRouterCallExpression(
  sourceFile: SourceFile
): CallExpression | null {
  const routerModuleForRootCalls = query(
    sourceFile.getText(),
    'PropertyAssignment:has(Identifier[name=providers]) > ArrayLiteralExpression CallExpression:has(Identifier[name=provideRouter])'
  ) as CallExpression[];

  return routerModuleForRootCalls.length ? routerModuleForRootCalls[0] : null;
}

function getRouterModuleForRootCallExpression(
  sourceFile: SourceFile
): CallExpression | null {
  const routerModuleForRootCalls = query(
    sourceFile.getText(),
    'Decorator > CallExpression:has(Identifier[name=NgModule]) PropertyAssignment:has(Identifier[name=imports]) > ArrayLiteralExpression CallExpression:has(Identifier[name=forRoot])'
  ) as CallExpression[];

  return routerModuleForRootCalls.length ? routerModuleForRootCalls[0] : null;
}
