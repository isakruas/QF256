QF256 technical report

From the project root:
  make study-analysis
  make report

The target runs pdfLaTeX twice and writes docs/report/qf256-report.pdf.
Main source: docs/report/qf256-report.tex, with study-methods.tex and
study-results.tex in the same directory. The bibliography is embedded.
Fortran writes the numerical tables in study/; GNUplot renders figures from
those results. Figure source: study/plots.gp. The analysis recomputes summaries
from the published measurements and does not run a simulation campaign.
To regenerate measurements with the included receiver, use the campaign
commands in study/README.md before these steps.

Requirements: pdfLaTeX, the article class, and the inputenc, fontenc, lmodern,
amsmath, amssymb, amsthm, booktabs, array, graphicx, geometry, microtype,
xcolor, hyperref and url packages.
Study analysis additionally requires GNU Fortran and GNUplot with
pdfcairo/pngcairo support. See study/README.md for the data and commands.

Layout: single-column 11pt A4 article with Latin Modern fonts, 2.8 cm margins,
numbered sections and equations, booktabs tables, title block, abstract and
native bibliography. Internal and citation links are black; URLs are blue.
