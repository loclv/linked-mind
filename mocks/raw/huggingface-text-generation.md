# Text Generation with Transformers

Text generation is the most popular application for large language models (LLMs). A LLM is trained to generate the next word (token) given some initial text (prompt) along with its own generated outputs up to a predefined length or when it reaches an end-of-sequence (`EOS`) token.

In Transformers, the `GenerationMixin.generate` API handles text generation, and it is available for all models with generative capabilities.

## Default generate

Before you begin, it's helpful to install `bitsandbytes` to quantize really large models to reduce their memory usage.

```bash
pip install -U transformers bitsandbytes
```

Load a LLM with `PreTrainedModel.from_pretrained` and add the following two parameters to reduce the memory requirements.

- `device_map="auto"` enables Accelerates' Big Model Inference feature for automatically initiating the model skeleton and loading and dispatching the model weights across all available devices, starting with the fastest device (GPU).
- `quantization_config` is a configuration object that defines the quantization settings. This examples uses bitsandbytes as the quantization backend and it loads the model in 4-bits.

```python
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig

quantization_config = BitsAndBytesConfig(load_in_4bit=True)
model = AutoModelForCausalLM.from_pretrained("mistralai/Mistral-7B-v0.1", device_map="auto", quantization_config=quantization_config)
```

Tokenize your input, and set the `padding_side` parameter to `"left"` because a LLM is not trained to continue generation from padding tokens. The tokenizer returns the input ids and attention mask.

```python
tokenizer = AutoTokenizer.from_pretrained("mistralai/Mistral-7B-v0.1", padding_side="left")
model_inputs = tokenizer(["A list of colors: red, blue"], return_tensors="pt").to(model.device)
```

Pass the inputs to `generate` to generate tokens, and `batch_decode` the generated tokens back to text.

```python
generated_ids = model.generate(**model_inputs)
tokenizer.batch_decode(generated_ids, skip_special_tokens=True)[0]
# "A list of colors: red, blue, green, yellow, orange, purple, pink,"
```

## Generation configuration

All generation settings are contained in `GenerationConfig`. In the example above, the generation settings are derived from the `generation_config.json` file of the model. A default decoding strategy is used when no configuration is saved with a model.

Inspect the configuration through the `generation_config` attribute. It only shows values that are different from the default configuration.

```python
from transformers import AutoModelForCausalLM

model = AutoModelForCausalLM.from_pretrained("mistralai/Mistral-7B-v0.1", device_map="auto")
model.generation_config
# GenerationConfig {
#   "bos_token_id": 1,
#   "eos_token_id": 2
# }
```

You can customize `generate` by overriding the parameters and values in `GenerationConfig`.

```python
# enable beam search sampling strategy
model.generate(**inputs, num_beams=4, do_sample=True)
```

`generate` can also be extended with external libraries or custom code:

1. the `logits_processor` parameter accepts custom `LogitsProcessor` instances for manipulating the next token probability distribution;
2. the `stopping_criteria` parameters supports custom `StoppingCriteria` to stop text generation;
3. other custom generation methods can be loaded through the `custom_generate` flag.

### Saving

Create an instance of `GenerationConfig` and specify the decoding parameters you want.

```python
from transformers import AutoModelForCausalLM, GenerationConfig

model = AutoModelForCausalLM.from_pretrained("my_account/my_model")
generation_config = GenerationConfig(
    max_new_tokens=50, do_sample=True, top_k=50, eos_token_id=model.config.eos_token_id
)

generation_config.save_pretrained("my_account/my_model", push_to_hub=True)
```

## Common Options

`GenerationMixin.generate` is a powerful tool that can be heavily customized. This section contains a list of popular generation options:

| Option name | Type | Simplified description |
|---|---|---|
| `max_new_tokens` | `int` | Controls the maximum generation length. Be sure to define it, as it usually defaults to a small value. |
| `do_sample` | `bool` | Defines whether generation will sample the next token (`True`), or is greedy instead (`False`). Most use cases should set this flag to `True`. |
| `temperature` | `float` | How unpredictable the next selected token will be. High values (`>0.8`) are good for creative tasks, low values (e.g. `<0.4`) for tasks that require "thinking". Requires `do_sample=True`. |
| `num_beams` | `int` | When set to `>1`, activates the beam search algorithm. Beam search is good on input-grounded tasks. |
| `repetition_penalty` | `float` | Set it to `>1.0` if you're seeing the model repeat itself often. Larger values apply a larger penalty. |
| `eos_token_id` | `list[int]` | The token(s) that will cause generation to stop. The default value is usually good, but you can specify a different token. |

## Pitfalls

### Output length

`generate` returns up to 20 tokens by default unless otherwise specified in a models `GenerationConfig`. It is highly recommended to manually set the number of generated tokens with the `max_new_tokens` parameter to control the output length. Decoder-only models returns the initial prompt along with the generated tokens.

```python
# Default length
generated_ids = model.generate(**model_inputs)
tokenizer.batch_decode(generated_ids, skip_special_tokens=True)[0]
# 'A sequence of numbers: 1, 2, 3, 4, 5'

# With max_new_tokens
generated_ids = model.generate(**model_inputs, max_new_tokens=50)
tokenizer.batch_decode(generated_ids, skip_special_tokens=True)[0]
# 'A sequence of numbers: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, ...'
```

### Bad prompting

The choice of prompt has a dramatic effect on output quality. For chat models, use the chat template instead of raw prompting.

```python
# Bad: raw prompt
model_inputs = tokenizer(["Write me an essay about AI."], return_tensors="pt").to(model.device)

# Good: chat template
messages = [{"role": "user", "content": "Write me an essay about AI."}]
model_inputs = tokenizer.apply_chat_template(messages, return_tensors="pt").to(model.device)
```
