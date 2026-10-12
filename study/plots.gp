# Render the Fortran-generated study tables. Run from the project root:
#   gnuplot study/plots.gp
# Requires GNUplot with pdfcairo and pngcairo terminals and a serif font.
# cells.csv columns 8, 9, 10 contain rate and asymmetric Wilson limits.
# Physical CDF values and proportions are already calculated in Fortran.
reset
set encoding utf8
set datafile separator comma
set datafile columnheaders
system "mkdir -p study/figures"

do for [format=1:2] {
    render_scale = (format == 1 ? 1.4 : 3.0)
    if (format == 1) {
        set terminal pdfcairo enhanced color font "Liberation Serif,14" size 7in,3.15in
        set output "study/figures/acceptance.pdf"
    } else {
        set terminal pngcairo enhanced font "Liberation Serif,30" size 2100,945
        set output "study/figures/acceptance.png"
    }
    set border 3 linewidth (0.65*render_scale)
    set tics nomirror out scale 0.5
    set grid xtics ytics back linewidth (0.4*render_scale) linecolor rgb "#dddddd"
    set xrange [-24.5:-13.5]
    set yrange [-0.025:1.04]
    set xtics -24,2,-14
    set ytics 0,0.2,1
    set format x "%.0f"
    set format y "%.1f"
    set xlabel "Reference level {/Symbol r} (dB; 2500 Hz)"
    set ylabel "Correct-message acceptance probability"
    legend_font = sprintf("Liberation Serif,%g",9*render_scale)
    set key left top noopaque samplen 1.6 spacing 1.1 font legend_font
    set bars 0.55
    set style line 1 linecolor rgb "#165a86" linewidth (1.25*render_scale) pointtype 7 pointsize (0.6*render_scale)
    set style line 2 linecolor rgb "#ae4828" linewidth (1.25*render_scale) pointtype 5 pointsize (0.6*render_scale)
    set style line 3 linecolor rgb "#407845" linewidth (1.25*render_scale) pointtype 9 pointsize (0.6*render_scale)
    set multiplot layout 1,2 margins 0.105,0.985,0.185,0.875 spacing 0.085,0
    do for [panel=1:2] {
        power = (panel == 1 ? "average" : "peak")
        set title (panel == 1 ? "(a) Unit-average transmit power" : "(b) Unit-peak transmit power")
        if (panel == 2) {
            unset ylabel
            unset key
            set format y ""
        }
        plot "study/cells.csv" using \
            ((strcol(1) eq "quiet" && strcol(2) eq power) ? column(3) : 1/0):8:9:10 \
            with yerrorlines linestyle 1 title "Quiet", \
            "study/cells.csv" using \
            ((strcol(1) eq "moderate" && strcol(2) eq power) ? column(3) : 1/0):8:9:10 \
            with yerrorlines linestyle 2 title "Moderate", \
            "study/cells.csv" using \
            ((strcol(1) eq "disturbed" && strcol(2) eq power) ? column(3) : 1/0):8:9:10 \
            with yerrorlines linestyle 3 title "Disturbed"
    }
    unset multiplot
    unset output
}

do for [format=1:2] {
    render_scale = (format == 1 ? 1.4 : 3.0)
    if (format == 1) {
        set terminal pdfcairo enhanced color font "Liberation Serif,14" size 7in,2.9in
        set output "study/figures/physical.pdf"
    } else {
        set terminal pngcairo enhanced font "Liberation Serif,30" size 2100,870
        set output "study/figures/physical.png"
    }
    set border 3 linewidth (0.65*render_scale)
    set tics nomirror out scale 0.5
    set grid xtics ytics back linewidth (0.4*render_scale) linecolor rgb "#dddddd"
    set yrange [0:1]
    set ytics 0,0.2,1
    set format y "%.1f"
    unset key
    set ylabel "Empirical cumulative fraction"
    set multiplot layout 1,2 margins 0.105,0.945,0.195,0.87 spacing 0.085,0
    set title "(a) 99% energy bandwidth"
    set xlabel "Bandwidth (Hz)"
    set autoscale x
    set xtics autofreq
    set format x "%.0f"
    plot "study/physical/bw99_cdf.csv" using 1:2 with steps \
        linecolor rgb "#165a86" linewidth (1.3*render_scale)
    unset ylabel
    set format y ""
    set title "(b) Oversampled envelope PAPR"
    set xlabel "PAPR (dB)"
    set autoscale x
    set xtics 0.00004
    set format x "%.5f"
    plot "study/physical/papr_cdf.csv" using 1:2 with steps \
        linecolor rgb "#165a86" linewidth (1.3*render_scale)
    unset multiplot
    unset output
}
