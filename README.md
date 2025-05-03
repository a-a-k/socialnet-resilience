[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.15332250.svg)](https://doi.org/10.5281/zenodo.15332250)

## Quick start

```bash
git clone https://github.com/a-a-k/socialnet-resilience
cd socialnet-resilience
chmod +x *.sh 00_helpers/*.sh

# baseline experiment (no replicas)
./pipeline_norepl.sh

# replica experiment
./pipeline_repl.sh
```

Output JSONs appear in `results/summary_*.json`.
