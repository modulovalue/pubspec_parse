// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

part 'dependency.g.dart';

Map<String, Dependency> parseDeps(Map source) =>
    source?.map((k, v) {
      final key = k as String;
      Dependency value;
      try {
        value = _fromJson(v);
      } on CheckedFromJsonException catch (e) {
        if (e.map is! YamlMap) {
          // This is likely a "synthetic" map created from a String value
          // Use `source` to throw this exception with an actual YamlMap and
          // extract the associated error information.
          throw CheckedFromJsonException(source, key, e.className, e.message);
        }
        rethrow;
      }

      if (value == null) {
        throw CheckedFromJsonException(
            source, key, 'Pubspec', 'Not a valid dependency value.');
      }
      return MapEntry(key, value);
    }) ??
    {};

const _sourceKeys = ['sdk', 'git', 'path', 'hosted'];

/// Returns `null` if the data could not be parsed.
Dependency _fromJson(dynamic data) {
  if (data is String || data == null) {
    return _$HostedDependencyFromJson({'version': data});
  }

  if (data is Map) {
    final matchedKeys =
        data.keys.cast<String>().where((key) => key != 'version').toList();

    if (data.isEmpty || (matchedKeys.isEmpty && data.containsKey('version'))) {
      return _$HostedDependencyFromJson(data);
    } else {
      final firstUnrecognizedKey = matchedKeys
          .firstWhere((k) => !_sourceKeys.contains(k), orElse: () => null);

      return $checkedNew<Dependency>('Dependency', data, () {
        if (firstUnrecognizedKey != null) {
          throw UnrecognizedKeysException(
              [firstUnrecognizedKey], data, _sourceKeys);
        }
        if (matchedKeys.length > 1) {
          throw CheckedFromJsonException(data, matchedKeys[1], 'Dependency',
              'A dependency may only have one source.');
        }

        final key = matchedKeys.single;

        switch (key) {
          case 'git':
            return GitDependency.fromData(data[key]);
          case 'path':
            return PathDependency.fromData(data[key]);
          case 'sdk':
            return _$SdkDependencyFromJson(data);
          case 'hosted':
            return _$HostedDependencyFromJson(data);
        }
        throw StateError('There is a bug in pubspec_parse.');
      });
    }
  }

  // Not a String or a Map – return null so parent logic can throw proper error
  return null;
}

abstract class Dependency {
  Dependency._();

  String get _info;

  T visit<T>(DependencyVisitor<T> visitor);

  @override
  String toString() => '$runtimeType: $_info';
}

@JsonSerializable()
class SdkDependency extends Dependency {
  @JsonKey(nullable: false, disallowNullValue: true, required: true)
  final String sdk;
  @JsonKey(fromJson: _constraintFromString)
  final VersionConstraint version;

  SdkDependency(this.sdk, {this.version}) : super._();

  @override
  T visit<T>(DependencyVisitor<T> visitor) {
    return visitor.sdk(this);
  }

  @override
  String get _info => sdk;
}

@JsonSerializable()
class GitDependency extends Dependency {
  @JsonKey(fromJson: parseGitUri, required: true, disallowNullValue: true)
  final Uri url;
  final String ref;
  final String path;

  GitDependency(this.url, this.ref, this.path) : super._();

  factory GitDependency.fromData(Object data) {
    if (data is String) {
      data = {'url': data};
    }

    if (data is Map) {
      return _$GitDependencyFromJson(data);
    }

    throw ArgumentError.value(data, 'git', 'Must be a String or a Map.');
  }

  @override
  String get _info => 'url@$url';

  @override
  T visit<T>(DependencyVisitor<T> visitor) {
    return visitor.git(this);
  }
}

Uri parseGitUri(String value) => _tryParseScpUri(value) ?? Uri.parse(value);

/// Supports URIs like `[user@]host.xz:path/to/repo.git/`
/// See https://git-scm.com/docs/git-clone#_git_urls_a_id_urls_a
Uri _tryParseScpUri(String value) {
  final colonIndex = value.indexOf(':');

  if (colonIndex < 0) {
    return null;
  } else if (colonIndex == value.indexOf('://')) {
    // If the first colon is part of a scheme, it's not an scp-like URI
    return null;
  }
  final slashIndex = value.indexOf('/');

  if (slashIndex >= 0 && slashIndex < colonIndex) {
    // Per docs: This syntax is only recognized if there are no slashes before
    // the first colon. This helps differentiate a local path that contains a
    // colon. For example the local path foo:bar could be specified as an
    // absolute path or ./foo:bar to avoid being misinterpreted as an ssh url.
    return null;
  }

  final atIndex = value.indexOf('@');
  if (colonIndex > atIndex) {
    final user = atIndex >= 0 ? value.substring(0, atIndex) : null;
    final host = value.substring(atIndex + 1, colonIndex);
    final path = value.substring(colonIndex + 1);
    return Uri(scheme: 'ssh', userInfo: user, host: host, path: path);
  }
  return null;
}

class PathDependency extends Dependency {
  final String path;

  PathDependency(this.path) : super._();

  factory PathDependency.fromData(Object data) {
    if (data is String) {
      return PathDependency(data);
    }
    throw ArgumentError.value(data, 'path', 'Must be a String.');
  }

  @override
  String get _info => 'path@$path';

  @override
  T visit<T>(DependencyVisitor<T> visitor) {
    return visitor.path(this);
  }
}

@JsonSerializable(disallowUnrecognizedKeys: true)
class HostedDependency extends Dependency {
  @JsonKey(fromJson: _constraintFromString)
  final VersionConstraint version;

  @JsonKey(disallowNullValue: true)
  final HostedDetails hosted;

  HostedDependency({VersionConstraint version, this.hosted})
      : version = version ?? VersionConstraint.any,
        super._();

  @override
  String get _info => version.toString();

  @override
  T visit<T>(DependencyVisitor<T> visitor) {
    return visitor.hosted(this);
  }
}

@JsonSerializable(disallowUnrecognizedKeys: true)
class HostedDetails {
  @JsonKey(required: true, disallowNullValue: true)
  final String name;

  @JsonKey(fromJson: parseGitUri, disallowNullValue: true)
  final Uri url;

  HostedDetails(this.name, this.url);

  factory HostedDetails.fromJson(Object data) {
    if (data is String) {
      data = {'name': data};
    }

    if (data is Map) {
      return _$HostedDetailsFromJson(data);
    }

    throw ArgumentError.value(data, 'hosted', 'Must be a Map or String.');
  }
}

VersionConstraint _constraintFromString(String input) =>
    VersionConstraint.parse(input);

abstract class DependencyVisitor<T> {
  factory DependencyVisitor.create({
    @required T Function(GitDependency dependency) gitDependency,
    @required T Function(HostedDependency dependency) hostedDependency,
    @required T Function(PathDependency dependency) pathDependency,
    @required T Function(SdkDependency dependency) sdkDependency,
  }) =>
      _AnonymousDependencyVisitor(
          gitDependency: gitDependency,
          hostedDependency: hostedDependency,
          pathDependency: pathDependency,
          sdkDependency: sdkDependency);

  T hosted(HostedDependency dependency);

  T path(PathDependency dependency);

  T sdk(SdkDependency dependency);

  T git(GitDependency dependency);

  const DependencyVisitor();
}

class _AnonymousDependencyVisitor<T> extends DependencyVisitor<T> {
  final T Function(GitDependency dependency) gitDependency;
  final T Function(HostedDependency dependency) hostedDependency;
  final T Function(PathDependency dependency) pathDependency;
  final T Function(SdkDependency dependency) sdkDependency;

  _AnonymousDependencyVisitor(
      {@required this.gitDependency,
      @required this.hostedDependency,
      @required this.pathDependency,
      @required this.sdkDependency});

  @override
  T git(GitDependency dependency) => gitDependency(dependency);

  @override
  T hosted(HostedDependency dependency) => hostedDependency(dependency);

  @override
  T path(PathDependency dependency) => pathDependency(dependency);

  @override
  T sdk(SdkDependency dependency) => sdkDependency(dependency);
}
