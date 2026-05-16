// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'otel_loops_suppression.dart';

const _tracerName = 'dartastic_otel_libs_loops';

Tracer _tracer() => OTel.tracerProvider().getTracer(_tracerName);

class LoopsResult {
  const LoopsResult({this.requestId, this.deliveryStatus});

  /// Loops request id from response.
  final String? requestId;

  /// `success` / `error` / `bounced` etc.
  final String? deliveryStatus;
}

class LoopsCallResult<T> {
  const LoopsCallResult({required this.value, this.result});
  final T value;
  final LoopsResult? result;
}

/// CLIENT span over Loops API calls. [operation] is one of:
/// `sendTransactional`, `sendEvent`, `createContact`, `updateContact`,
/// `deleteContact`, `findContact`, `getCustomFields`.
///
/// For email-sending ops uses messaging.* semconv; for contact CRUD
/// the span just keeps loops.operation as the primary dimension.
Future<T> tracedLoops<T>({
  required String operation,
  required Future<LoopsCallResult<T>> Function() invoke,
  String? transactionalId,
  String? eventName,
  String? recipientEmail,
}) async {
  if (loopsInstrumentationSuppressed()) {
    final r = await invoke();
    return r.value;
  }
  final isEmail = operation == 'sendTransactional';
  final m = <String, Object>{
    'loops.operation': operation,
  };
  if (isEmail) {
    m['messaging.system'] = 'loops';
    m['messaging.operation'] = 'publish';
    m['messaging.destination.kind'] = 'email';
    if (transactionalId != null) {
      m['messaging.destination.name'] = transactionalId;
      m['loops.transactional.id'] = transactionalId;
    }
  } else if (operation == 'sendEvent' && eventName != null) {
    m['loops.event.name'] = eventName;
  }
  if (recipientEmail != null) {
    m['loops.recipient.email'] = recipientEmail;
  }

  final spanName = switch (operation) {
    'sendTransactional' => 'loops send ${transactionalId ?? 'transactional'}',
    'sendEvent' => 'loops event ${eventName ?? ''}',
    _ => 'loops $operation',
  };

  final span = _tracer().startSpan(
    spanName,
    kind: isEmail ? SpanKind.producer : SpanKind.client,
    attributes: OTel.attributesFromMap(m),
  );
  try {
    final r = await invoke();
    if (r.result != null) {
      final extras = <Attribute<Object>>[];
      if (r.result!.requestId != null) {
        extras.add(OTel.attributeString(
          'loops.request.id',
          r.result!.requestId!,
        ));
        if (isEmail) {
          extras.add(OTel.attributeString(
            'messaging.message.id',
            r.result!.requestId!,
          ));
        }
      }
      if (r.result!.deliveryStatus != null) {
        extras.add(OTel.attributeString(
          'loops.delivery_status',
          r.result!.deliveryStatus!,
        ));
        if (r.result!.deliveryStatus == 'error' ||
            r.result!.deliveryStatus == 'bounced') {
          span.setStatus(
            SpanStatusCode.Error,
            'Loops delivery_status=${r.result!.deliveryStatus}',
          );
        }
      }
      if (extras.isNotEmpty) span.addAttributes(OTel.attributes(extras));
    }
    return r.value;
  } catch (e, st) {
    span.addAttributes(OTel.attributes([
      OTel.attributeString(
        ErrorResource.errorType.key,
        e.runtimeType.toString(),
      ),
    ]));
    span.recordException(e, stackTrace: st);
    span.setStatus(SpanStatusCode.Error, e.toString());
    rethrow;
  } finally {
    span.end();
  }
}
