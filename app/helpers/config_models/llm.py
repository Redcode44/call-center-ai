from enum import Enum

from azure.ai.inference.aio import ChatCompletionsClient
from openai import AsyncOpenAI
from pydantic import BaseModel, SecretStr, ValidationInfo, field_validator

from app.helpers.cache import lru_acache
from app.helpers.http import azure_transport
from app.helpers.identity import credential


class ModeEnum(str, Enum):
    AZURE_OPENAI = "azure_openai"
    """Use Azure OpenAI, through the Azure AI Inference API."""
    NVIDIA = "nvidia"
    """Use the NVIDIA API (OpenAI-compatible), e.g. for Nemotron models."""


class DeploymentModel(BaseModel, frozen=True):
    api_version: str = "2024-10-21"  # See: https://learn.microsoft.com/en-us/azure/ai-services/openai/reference#api-specs
    context: int
    endpoint: str
    mode: ModeEnum = ModeEnum.AZURE_OPENAI
    model: str
    nvidia_api_key: SecretStr | None = None
    reasoning_budget: int = 16384  # Only used in NVIDIA mode
    seed: int = 42  # Reproducible results
    temperature: float = 0.0  # Most focused and deterministic
    top_p: float = 0.95  # Only used in NVIDIA mode

    @field_validator("nvidia_api_key")
    @classmethod
    def _validate_nvidia_api_key(
        cls,
        nvidia_api_key: SecretStr | None,
        info: ValidationInfo,
    ) -> SecretStr | None:
        if not nvidia_api_key and info.data.get("mode") == ModeEnum.NVIDIA:
            raise ValueError("NVIDIA API key required")
        return nvidia_api_key

    @lru_acache()
    async def client(
        self,
    ) -> tuple[ChatCompletionsClient | AsyncOpenAI, "DeploymentModel"]:
        if self.mode == ModeEnum.NVIDIA:
            assert self.nvidia_api_key
            return AsyncOpenAI(
                api_key=self.nvidia_api_key.get_secret_value(),
                base_url=self.endpoint,
            ), self

        return ChatCompletionsClient(
            # Reliability
            seed=self.seed,
            temperature=self.temperature,
            # Deployment
            api_version=self.api_version,
            endpoint=self.endpoint,
            model=self.model,
            # Performance
            transport=await azure_transport(),
            # Authentication
            credential_scopes=["https://cognitiveservices.azure.com/.default"],
            credential=await credential(),
        ), self


class LlmModel(BaseModel):
    fast: DeploymentModel
    slow: DeploymentModel

    def selected(self, is_fast: bool) -> DeploymentModel:
        return self.fast if is_fast else self.slow
