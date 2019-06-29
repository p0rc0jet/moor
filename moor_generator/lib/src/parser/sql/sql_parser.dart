import 'package:analyzer/dart/constant/value.dart';
import 'package:moor_generator/src/errors.dart';
import 'package:moor_generator/src/model/specified_column.dart';
import 'package:moor_generator/src/model/specified_table.dart';
import 'package:moor_generator/src/model/sql_query.dart';
import 'package:moor_generator/src/options.dart';
import 'package:sqlparser/sqlparser.dart' hide ResultColumn;

import 'affected_tables_visitor.dart';

class SqlParser {
  final MoorOptions options;
  final List<SpecifiedTable> tables;
  final List<DartObject> definedQueries;

  SqlEngine _engine;
  final Map<Table, SpecifiedTable> _engineTablesToSpecified = {};

  final List<SqlQuery> foundQueries = [];
  final List<MoorError> errors = [];

  SqlParser(this.options, this.tables, this.definedQueries);

  void _spawnEngine() {
    _engine = SqlEngine();
    tables.map(_extractStructure).forEach(_engine.registerTable);
  }

  /// Convert a [SpecifiedTable] from moor into something that can be understood
  /// by the sqlparser library.
  Table _extractStructure(SpecifiedTable table) {
    final columns = <TableColumn>[];
    for (var specified in table.columns) {
      final type = _resolveForColumnType(specified.type)
          .withNullable(specified.nullable);
      columns.add(TableColumn(specified.name.name, type));
    }

    final engineTable = Table(name: table.sqlName, resolvedColumns: columns);
    _engineTablesToSpecified[engineTable] = table;
    return engineTable;
  }

  ResolvedType _resolveForColumnType(ColumnType type) {
    switch (type) {
      case ColumnType.integer:
        return const ResolvedType(type: BasicType.int);
      case ColumnType.text:
        return const ResolvedType(type: BasicType.text);
      case ColumnType.boolean:
        return const ResolvedType(type: BasicType.int, hint: IsBoolean());
      case ColumnType.datetime:
        return const ResolvedType(type: BasicType.int, hint: IsDateTime());
      case ColumnType.blob:
        return const ResolvedType(type: BasicType.blob);
      case ColumnType.real:
        return const ResolvedType(type: BasicType.real);
    }
    throw StateError('cant happen');
  }

  ColumnType _resolvedToMoor(ResolvedType type) {
    if (type == null) {
      return ColumnType.text;
    }

    switch (type.type) {
      case BasicType.nullType:
        return ColumnType.text;
      case BasicType.int:
        if (type.hint is IsBoolean) {
          return ColumnType.boolean;
        } else if (type.hint is IsDateTime) {
          return ColumnType.datetime;
        }
        return ColumnType.integer;
      case BasicType.real:
        return ColumnType.real;
      case BasicType.text:
        return ColumnType.text;
      case BasicType.blob:
        return ColumnType.blob;
    }
    throw StateError('Unexpected type: $type');
  }

  void parse() {
    _spawnEngine();

    for (var query in definedQueries) {
      final name = query.getField('name').toStringValue();
      final sql = query.getField('query').toStringValue();

      AnalysisContext context;
      try {
        context = _engine.analyze(sql);
      } catch (e, s) {
        errors.add(MoorError(
            critical: true,
            message: 'Error while trying to parse $sql: $e, $s'));
      }

      for (var error in context.errors) {
        errors.add(MoorError(
          message: 'The sql query $sql is invalid: ${error.message}',
        ));
      }

      final root = context.root;
      if (root is SelectStatement) {
        _handleSelect(name, root, context);
      } else {
        throw StateError('Unexpected sql, expected a select statement');
      }
    }
  }

  void _handleSelect(
      String queryName, SelectStatement stmt, AnalysisContext ctx) {
    final tableFinder = AffectedTablesVisitor();
    stmt.accept(tableFinder);

    final foundTables = tableFinder.foundTables;
    final moorTables = foundTables.map((t) => _engineTablesToSpecified[t]);
    final resultColumns = stmt.resolvedColumns;

    final moorColumns = <ResultColumn>[];
    for (var column in resultColumns) {
      final type = ctx.typeOf(column).type;
      moorColumns
          .add(ResultColumn(column.name, _resolvedToMoor(type), type.nullable));
    }

    final resultSet = InferredResultSet(null, moorColumns);
    final foundVars = _extractVariables(ctx);
    foundQueries.add(SqlSelectQuery(
        queryName, ctx.sql, foundVars, moorTables.toList(), resultSet));
  }

  List<FoundVariable> _extractVariables(AnalysisContext ctx) {
    // this contains variable references. For instance, SELECT :a = :a would
    // contain two entries, both referring to the same variable. To do that,
    // we use the fact that each variable has a unique index.
    final usedVars = ctx.root.allDescendants.whereType<Variable>().toList()
      ..sort((a, b) => a.resolvedIndex.compareTo(b.resolvedIndex));

    final foundVariables = <FoundVariable>[];
    var currentIndex = 0;

    for (var used in usedVars) {
      if (used.resolvedIndex == currentIndex) {
        continue; // already handled
      }

      currentIndex++;
      final name = (used is ColonNamedVariable) ? used.name : null;
      final type = _resolvedToMoor(ctx.typeOf(used).type);

      foundVariables.add(FoundVariable(currentIndex, name, type));
    }

    return foundVariables;
  }
}