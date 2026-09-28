# Project Post-Mortem & Developer Experience Log: Agri-Market Pipeline

## Overview
This repository contains an end-to-end serverless data pipeline designed to ingest Nigerian agricultural market commodity prices (staples like rice, beans, and garri), land raw JSON payloads into Azure Blob Storage, and automatically stage them into an Azure SQL database using Azure Functions (`func-agri-v1a564`).

Building and deploying this pipeline from scratch over the course of a week came with a steep learning curve, heavy infrastructure wiring, and plenty of lessons learned in the trenches.

---

## The Good, The Bad, & The Wire: Real-World Experience

### 1. Frontend vs. Backend Reality
* **The Experience:** On the surface, building the logic feels straightforward. In reality, the backend is a complex web of wiring. Connecting local tools to Azure introduced constant friction—particularly around Microsoft Entra ID (Azure AD), subscription keys, account authentications, and configuration paths. 
* **The Lesson:** Getting cloud accounts and local development environments to talk to each other securely is often 80% of the battle before writing core application logic.

### 2. The Terraform Experiment
* **The Experience:** Utilizing Terraform felt like learning an entirely separate dialect just to translate infrastructure intentions into Azure's language. Keeping state synchronized—especially trying to link it cleanly with GitHub pipelines—was a major stress test.
* **The Lesson:** For future projects, the strategy is clear: bypass the heavy Infrastructure-as-Code overhead, lean straight into VS Code and streamlined deployments, and keep things simple and practical.

### 3. The JSON & Data Parsing Grind
* **The Experience:** Wrestling with JSON payloads, blob storage directory structures, and SQL staging procedures (`OPENJSON`) required a lot of reverse-engineering. Revisiting SQL after a two-year hiatus made successfully seeing structured rows land in `dbo.stg_market_prices` a deeply satisfying win.
* **The Lesson:** Clean, predictable data payloads are the lifeblood of any pipeline. 

### 4. Theory vs. The Trenches (Cloud Certifications)
* **The Experience:** Concepts picked up from cloud studies (like `AZ-900`) finally stopped being abstract textbook definitions and started making brutal, practical sense once applied in a live deployment setting.
* **The Lesson:** Building a multi-service serverless architecture in a week provides a mental model that passive reading simply cannot match.

---

## Key Takeaways for Future Iterations
1. **Ditch Heavy IaC for Quick Prototypes:** Skip Terraform on rapid single-developer prototypes; lean on native CLI tools and VS Code extensions.
2. **Watch the Local Environment Footprint:** Always maintain a tight `.funcignore` file to prevent local virtual environments (`.venv`) from choking remote zip deployments.
3. **Simplicity Wins:** The next iteration of this project will prioritize a stripped-down, streamlined stack to minimize configuration overhead.

---

*Notes contributed by Christopher Odiyi*