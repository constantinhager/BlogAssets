# Run 'tflint --init' once, then 'tflint' in this folder (both are in the dev container image).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
