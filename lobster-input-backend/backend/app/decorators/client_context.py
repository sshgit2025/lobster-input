"""Inject the shared client request context into authenticated HTTP endpoints.

The decorator owns the FastAPI ``Request``/authentication plumbing and keeps
header parsing out of business handlers.  Endpoint functions only receive a
``ClientRequestContext`` containing the values they actually use.
"""
from __future__ import annotations

import inspect
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Awaitable, Callable, TypeVar, get_type_hints

from fastapi import Depends, Request

from app.middleware.auth import verify_user
from app.services.pipeline.flow import PipelineManager

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline

_CONTEXT_PARAMETER = "client_context"
_ACCEPT_LANGUAGE_HEADER = "X-Accept-Language"

Endpoint = TypeVar("Endpoint", bound=Callable[..., Awaitable[Any]])


@dataclass(frozen=True, slots=True)
class ClientContextPolicy:
    """Configuration attached to a decorated endpoint for auditability."""

    client_platform: str
    fixed_flow_name: str | None = None


@dataclass(frozen=True, slots=True)
class ClientRequestContext:
    """Shared, immutable request values consumed by client business routes."""

    client_platform: str
    client_ui_lang: str
    flow_name: str
    user_email: str

    def get_pipeline(self, operation: str) -> "AudioProcessPipeline":
        """Resolve a v1 pipeline without exposing header parsing to the route."""
        return PipelineManager.get_pipeline(
            self.client_platform,
            operation,
            self.client_ui_lang,
        )


def with_client_context(
    *,
    client_platform: str,
    flow_name: str | None = None,
) -> Callable[[Endpoint], Endpoint]:
    """Inject ``ClientRequestContext`` and hide framework plumbing.

    ``flow_name=None`` preserves the v1 language-based flow selection.  Passing
    a value such as ``"v2"`` pins routes whose flow is version-defined.
    """
    policy = ClientContextPolicy(
        client_platform=client_platform,
        fixed_flow_name=flow_name,
    )

    async def resolve_client_context(
        request: Request,
        auth_payload: dict = Depends(verify_user),
    ) -> ClientRequestContext:
        client_ui_lang = request.headers.get(_ACCEPT_LANGUAGE_HEADER, "")
        resolved_flow_name = (
            policy.fixed_flow_name
            if policy.fixed_flow_name is not None
            else PipelineManager.get_flow_name(client_ui_lang)
        )
        return ClientRequestContext(
            client_platform=policy.client_platform,
            client_ui_lang=client_ui_lang,
            flow_name=resolved_flow_name,
            user_email=str(auth_payload.get("sub") or ""),
        )

    def decorator(endpoint: Endpoint) -> Endpoint:
        if not inspect.iscoroutinefunction(endpoint):
            raise TypeError("with_client_context only supports async endpoints")

        endpoint_signature = _resolved_signature(endpoint)
        context_parameter = endpoint_signature.parameters.get(_CONTEXT_PARAMETER)
        if context_parameter is None:
            raise TypeError(
                f"{endpoint.__qualname__} must declare a '{_CONTEXT_PARAMETER}' parameter"
            )
        if context_parameter.kind is inspect.Parameter.POSITIONAL_ONLY:
            raise TypeError("client_context cannot be positional-only")

        public_parameters = [
            parameter
            for name, parameter in endpoint_signature.parameters.items()
            if name != _CONTEXT_PARAMETER
        ]
        public_parameters.append(
            context_parameter.replace(
                kind=inspect.Parameter.KEYWORD_ONLY,
                default=Depends(resolve_client_context),
            )
        )
        public_signature = endpoint_signature.replace(parameters=public_parameters)
        endpoint.__signature__ = public_signature  # type: ignore[attr-defined]
        endpoint.__client_context_policy__ = policy  # type: ignore[attr-defined]
        return endpoint

    return decorator


def _resolved_signature(endpoint: Callable[..., Any]) -> inspect.Signature:
    """Resolve postponed annotations in the endpoint's defining module."""
    signature = inspect.signature(endpoint)
    type_hints = get_type_hints(endpoint)
    parameters = [
        parameter.replace(annotation=type_hints.get(name, parameter.annotation))
        for name, parameter in signature.parameters.items()
    ]
    return signature.replace(
        parameters=parameters,
        return_annotation=type_hints.get("return", signature.return_annotation),
    )
