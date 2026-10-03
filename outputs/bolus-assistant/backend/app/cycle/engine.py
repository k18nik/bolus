from datetime import date,timedelta

PHASE_LABELS={'menstrual':'Менструальная фаза','early_follicular':'Ранняя фолликулярная фаза','late_follicular':'Поздняя фолликулярная фаза','ovulatory':'Предполагаемая овуляция','early_luteal':'Ранняя лютеиновая фаза','mid_luteal':'Средняя лютеиновая фаза','late_luteal':'Поздняя лютеиновая фаза','unknown':'Фаза неизвестна'}
def cycle_status(start: date, length: int, today: date, actual_ovulation: date|None=None) -> dict:
    day=(today-start).days+1
    ovulation=(actual_ovulation-start).days+1 if actual_ovulation else length-14
    phase='unknown'
    if 1<=day<=length:
        if day<=5: phase='menstrual'
        elif day<ovulation-4: phase='early_follicular'
        elif day<ovulation-1: phase='late_follicular'
        elif day<=ovulation+1: phase='ovulatory'
        elif day<=ovulation+4: phase='early_luteal'
        elif day<=length-5: phase='mid_luteal'
        else: phase='late_luteal'
    return {'day':day,'phase':phase,'label':PHASE_LABELS[phase],'estimated':actual_ovulation is None,'cycle_length':length,'predicted_ovulation_date':(start+timedelta(days=ovulation-1)).isoformat()}
