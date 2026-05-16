// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:otel_loops/otel_loops.dart';
import 'package:test/test.dart';

void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(
      serviceName: 'otel_loops-test',
    );
    spans = harness.spans;
  });

  setUp(() => harness.clear());

  Map<String, Object> attrsOf(Span s) =>
      {for (final a in s.attributes.toList()) a.key: a.value};

  test('sendTransactional emits PRODUCER span', () async {
    await tracedLoops<String>(
      operation: 'sendTransactional',
      transactionalId: 'cl_xyz',
      recipientEmail: 'a@b.com',
      invoke: () async => const LoopsCallResult(
        value: 'ok',
        result: LoopsResult(requestId: 'r-1', deliveryStatus: 'success'),
      ),
    );
    final span = spans.findSpanByName('loops send cl_xyz')!;
    expect(span.kind, SpanKind.producer);
    final a = attrsOf(span);
    expect(a['messaging.system'], 'loops');
    expect(a['loops.transactional.id'], 'cl_xyz');
    expect(a['loops.recipient.email'], 'a@b.com');
    expect(a['messaging.message.id'], 'r-1');
  });

  test('bounced status sets span error', () async {
    await tracedLoops<String>(
      operation: 'sendTransactional',
      transactionalId: 't',
      invoke: () async => const LoopsCallResult(
        value: 'ok',
        result: LoopsResult(deliveryStatus: 'bounced'),
      ),
    );
    expect(
      spans.findSpanByName('loops send t')!.status,
      SpanStatusCode.Error,
    );
  });

  test('contact CRUD is CLIENT span without messaging.*', () async {
    await tracedLoops<String>(
      operation: 'updateContact',
      invoke: () async => const LoopsCallResult(value: 'ok'),
    );
    final span = spans.findSpanByName('loops updateContact')!;
    expect(span.kind, SpanKind.client);
    final a = attrsOf(span);
    expect(a.containsKey('messaging.system'), isFalse);
    expect(a['loops.operation'], 'updateContact');
  });

  test('suppression skips spans', () async {
    await runWithoutLoopsInstrumentationAsync(() async {
      await tracedLoops<String>(
        operation: 'sendTransactional',
        invoke: () async => const LoopsCallResult(value: 'v'),
      );
    });
    expect(spans.findSpansStartingWith('loops '), isEmpty);
  });
}
