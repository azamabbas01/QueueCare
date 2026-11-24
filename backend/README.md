# QueueCare API

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
uvicorn app.main:app --reload
python -m pytest tests -q
```

Modules: `main.py` (auth, MFA, public directory), `routes_patient.py`, `routes_doctor.py`, `routes_staff.py` (reception + nurse), `routes_admin.py`, `security.py` (token verification, MFA/password gates), `common.py` (audit, validation, queue maths), `photos.py`, `pdf.py`, `sms.py`, `gotrue.py`.
Admin bootstrap: `python scripts/create_admin.py --help`.
